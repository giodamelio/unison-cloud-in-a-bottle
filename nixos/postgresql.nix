{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  bundled = cfg.database.mode == "bundled";
  pg =
    if bundled
    then cfg.database.package
    else config.services.postgresql.package;
  user = "unison-cloud-postgres";
  # The role that owns the server: our own user for the bundled one, `postgres` on the host.
  superuser =
    if bundled
    then user
    else "postgres";
  dataDir = "${cfg.stateDir}/postgresql/${lib.versions.major pg.version}";

  roleSql = name: role: ''
    SELECT format('CREATE ROLE %I', '${name}') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${name}') \gexec
    ALTER ROLE "${name}" LOGIN ${lib.optionalString (!role.createdb) "NO"}CREATEDB;
  '';
  databaseSql = name: db: ''
    SELECT format('CREATE DATABASE %I OWNER %I', '${name}', '${db.owner}') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${name}') \gexec
    \c "${name}"
    ${lib.concatMapStrings (ext: "CREATE EXTENSION IF NOT EXISTS \"${ext}\";\n") db.extensions}
  '';
  setupSql = pkgs.writeText "unison-cloud-postgresql-setup.sql" (
    lib.concatStrings (lib.mapAttrsToList roleSql cfg.internal.postgresRoles)
    + lib.concatStrings (lib.mapAttrsToList databaseSql cfg.internal.postgresDatabases)
  );
in {
  options.services.unison-cloud.database.mode = lib.mkOption {
    type = lib.types.enum ["bundled" "host"];
    default = "bundled";
    description = ''
      Where the databases live. `bundled` runs the module's own Postgres inside the
      namespace, socket-only. `host` uses the host's `services.postgresql`: the module
      creates its roles, databases and extensions there, and every service connects over
      `/run/postgresql` with peer authentication, which the network namespace doesn't affect.
    '';
  };

  options.services.unison-cloud.internal = {
    postgresSocketDir = lib.mkOption {
      type = lib.types.str;
      internal = true;
      readOnly = true;
      default =
        if bundled
        then "/run/unison-cloud-postgresql"
        else "/run/postgresql";
      description = "Directory holding the Postgres Unix socket every service connects through.";
    };

    postgresUnit = lib.mkOption {
      type = lib.types.str;
      internal = true;
      readOnly = true;
      default =
        if bundled
        then "unison-cloud-postgresql.service"
        else "postgresql.service";
      description = "The unit running the Postgres server.";
    };

    postgresRoles = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options.createdb = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
      });
      internal = true;
      default = {};
      description = "Login roles to create, named after the system user that connects with peer authentication.";
    };

    postgresDatabases = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          owner = lib.mkOption {type = lib.types.str;};
          extensions = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Extensions to create as superuser, for migrations that can't create untrusted ones as the owner.";
          };
        };
      });
      internal = true;
      default = {};
      description = "Databases to create, each owned by one of the roles above.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = bundled || config.services.postgresql.enable;
          message = "services.unison-cloud: database.mode = \"host\" needs services.postgresql.enable = true.";
        }
      ];

      systemd.tmpfiles.settings.unison-cloud-state.${cfg.stateDir}.d = {
        user = "root";
        group = "root";
        mode = "0755";
      };

      systemd.services.unison-cloud-postgresql-setup = lib.mkMerge [
        cfg.internal.inNamespace
        {
          description = "Create Unison Cloud database roles, databases and extensions";
          requires = [cfg.internal.postgresUnit];
          after = [cfg.internal.postgresUnit];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = superuser;
            Group = superuser;
            ExecStart = "${pg}/bin/psql -h ${cfg.internal.postgresSocketDir} -d postgres -X -v ON_ERROR_STOP=1 -f ${setupSql}";
          };
        }
      ];
    }

    (lib.mkIf bundled {
      users.users.${user} = {
        isSystemUser = true;
        group = user;
      };
      users.groups.${user} = {};

      systemd.tmpfiles.settings.unison-cloud-postgresql."${cfg.stateDir}/postgresql".d = {
        inherit user;
        group = user;
        mode = "0700";
      };

      systemd.services.unison-cloud-postgresql = lib.mkMerge [
        cfg.internal.inNamespace
        {
          description = "Unison Cloud bundled PostgreSQL";
          serviceConfig = {
            Type = "notify";
            User = user;
            Group = user;
            RuntimeDirectory = baseNameOf cfg.internal.postgresSocketDir;
            RuntimeDirectoryMode = "0755";
            ExecStartPre = pkgs.writeShellScript "unison-cloud-postgresql-init" ''
              if [ ! -e ${dataDir}/PG_VERSION ]; then
                mkdir -p ${dataDir}
                ${pg}/bin/initdb -D ${dataDir} --auth-local=peer --auth-host=reject \
                  --encoding=UTF8 --locale=C --no-instructions
              fi
            '';
            # No TCP listener at all; peer authentication over the socket is the only way in.
            ExecStart = "${pg}/bin/postgres -D ${dataDir} -c listen_addresses= -c unix_socket_directories=${cfg.internal.postgresSocketDir}";
            ExecReload = "${lib.getExe' pkgs.coreutils "kill"} -HUP $MAINPID";
            KillMode = "mixed";
            KillSignal = "SIGINT";
            TimeoutSec = 120;
          };
        }
      ];
    })
  ]);
}
