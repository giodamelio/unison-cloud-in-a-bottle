{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  bundled = cfg.database.mode == "bundled";
  external = cfg.database.mode == "external";
  ext = cfg.database.external;
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

  roleSql = name: role:
    ''
      SELECT format('CREATE ROLE %I', '${name}') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${name}') \gexec
      ALTER ROLE "${name}" LOGIN NOSUPERUSER NOCREATEROLE NOREPLICATION NOBYPASSRLS ${lib.optionalString (!role.createdb) "NO"}CREATEDB;
    ''
    + lib.optionalString (role.passwordCredential != null) ''
      \set password `${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/${role.passwordCredential}"`
      ALTER ROLE "${name}" PASSWORD :'password';
    '';
  passwordCredentials = lib.filter (name: name != null) (lib.mapAttrsToList (_: role: role.passwordCredential) cfg.internal.postgresRoles);

  # Peer authentication over the socket for every service, and a password over TCP only
  # for the roles that can't use a socket, each into its own database.
  hbaFile = pkgs.writeText "unison-cloud-pg_hba.conf" (
    ''
      local all all peer
    ''
    + lib.concatStrings (lib.mapAttrsToList (name: db:
      lib.optionalString (cfg.internal.postgresRoles.${db.owner}.passwordCredential or null != null) ''
        host "${name}" "${db.owner}" 127.0.0.1/32 scram-sha-256
      '')
    cfg.internal.postgresDatabases)
  );
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
  options.services.unison-cloud.database = {
    mode = lib.mkOption {
      type = lib.types.enum ["bundled" "host" "external"];
      default = "bundled";
      description = ''
        Where the databases live. `bundled` runs the module's own Postgres inside the
        namespace. Services connect over its socket, except nimbus, which can't open a
        unix socket and logs in with a password on the namespace loopback. `host` uses the
        host's `services.postgresql`: the module creates its roles, databases and
        extensions there, and every service connects over `/run/postgresql` with peer
        authentication, which the network namespace doesn't affect. nimbus reaches the
        host's `127.0.0.1` through a bridge instead, with a password. `external` connects
        over TCP with passwords to a server you prepare yourself (see
        `database.external`); add its address to `egress.allowedDestinations`.

        In `host` mode the module never edits `pg_hba.conf`. It relies on NixOS's defaults,
        `local all all peer` and `host all all 127.0.0.1/32 md5`, or any rules that let each
        `unison-cloud-*` system user log in as the role of the same name, and
        `unison-cloud-nimbus` log in with its password from `127.0.0.1`. Its roles are
        `NOSUPERUSER`, `NOCREATEROLE` and `NOCREATEDB`.
      '';
    };

    external = {
      host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Address of the external Postgres server.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 5432;
      };

      cloudApi = {
        user = lib.mkOption {
          type = lib.types.str;
          default = "unison_cloud";
          description = ''
            Role cloud-api connects as. It must own `cloudApi.database`, and the
            `uuid-ossp`, `citext` and `moddatetime` extensions must already exist in that
            database, because creating `moddatetime` needs a superuser.
          '';
        };

        database = lib.mkOption {
          type = lib.types.str;
          default = "unison_cloud";
        };

        passwordFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
      };

      nimbus = {
        user = lib.mkOption {
          type = lib.types.str;
          default = "unison_cloud_nimbus";
          description = ''
            Role nimbus connects as. It must own `nimbus.database`, or at least be able to
            create a table in its `public` schema, because the module creates nimbus's
            storage table as this role. Don't let cloud-api's role read that database, or
            this role read cloud-api's: nimbus runs hosted code.
          '';
        };

        database = lib.mkOption {
          type = lib.types.str;
          default = "unison_cloud_nimbus";
        };

        passwordFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
      };
    };
  };

  options.services.unison-cloud.internal = {
    postgres = lib.mkOption {
      type = lib.types.attrs;
      internal = true;
      readOnly = true;
      default = {
        inherit external;
        host =
          if external
          then ext.host
          else cfg.internal.postgresSocketDir;
        port = toString (
          if external
          then ext.port
          else 5432
        );
      };
      description = "Where every service connects: a socket directory, or the external server.";
    };

    postgresTcp = lib.mkOption {
      type = lib.types.attrs;
      internal = true;
      readOnly = true;
      default =
        if external
        then {inherit (ext) host port;}
        else {
          host = "127.0.0.1";
          port = 5432;
        };
      description = ''
        Where a service that can't use a socket connects over TCP: the external server, or
        the namespace loopback, where the bundled server or the bridge to the host's
        server listens.
      '';
    };

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
        options = {
          createdb = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          passwordCredential = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Secret to set as the role's password on every start, which also lets it log in
              to the databases it owns over TCP on the bundled server's loopback.
            '';
          };
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
          assertion = cfg.database.mode != "host" || config.services.postgresql.enable;
          message = "services.unison-cloud: database.mode = \"host\" needs services.postgresql.enable = true.";
        }
        {
          assertion = !external || (ext.host != null && ext.cloudApi.passwordFile != null && ext.nimbus.passwordFile != null);
          message = "services.unison-cloud: database.mode = \"external\" needs database.external.host and both passwordFile options.";
        }
      ];

      systemd.tmpfiles.settings.unison-cloud-state.${cfg.stateDir}.d = {
        user = "root";
        group = "root";
        mode = "0755";
      };

      systemd.services.unison-cloud-postgresql-setup = lib.mkMerge [
        cfg.internal.inNamespace
        (lib.mkIf external {
          description = "Wait for the external Postgres server";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            DynamicUser = true;
            ExecStart = pkgs.writeShellScript "unison-cloud-postgresql-wait" ''
              until ${cfg.database.package}/bin/pg_isready -h ${ext.host} -p ${toString ext.port}; do sleep 1; done
            '';
            TimeoutStartSec = 300;
          };
        })
        (lib.mkIf (!external) {
          description = "Create Unison Cloud database roles, databases and extensions";
          requires = [cfg.internal.postgresUnit "unison-cloud-secrets.service"];
          after = [cfg.internal.postgresUnit "unison-cloud-secrets.service"];
          serviceConfig = lib.mkMerge [
            (cfg.internal.loadSecrets passwordCredentials)
            {
              Type = "oneshot";
              RemainAfterExit = true;
              User = superuser;
              Group = superuser;
              ExecStart = "${pg}/bin/psql -h ${cfg.internal.postgresSocketDir} -d postgres -X -v ON_ERROR_STOP=1 -f ${setupSql}";
            }
          ];
        })
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
            # The TCP listener is on the namespace loopback, and the namespace firewall limits
            # who reaches it. The module's own hba file replaces initdb's on every start.
            ExecStart = "${pg}/bin/postgres -D ${dataDir} -c listen_addresses=${cfg.internal.postgresTcp.host} -c port=${toString cfg.internal.postgresTcp.port} -c unix_socket_directories=${cfg.internal.postgresSocketDir} -c hba_file=${hbaFile}";
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
