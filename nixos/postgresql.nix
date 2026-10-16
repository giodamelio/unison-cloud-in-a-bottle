{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  db = cfg.database;
  pg = db.package;
  user = "unison-cloud-postgres";
  socketDir = "/run/unison-cloud-postgresql";
  dataDir = "${cfg.stateDir}/postgresql/${lib.versions.major pg.version}";

  # Each role logs in with its password over loopback TCP, into its own database only.
  roles = {
    ${db.cloudApi.user} = "cloud-api-db-password";
    ${db.nimbus.user} = "nimbus-db-password";
  };
  databases = {
    # Untrusted extensions a database owner can't create; the migrations skip them once they exist.
    ${db.cloudApi.database} = {
      owner = db.cloudApi.user;
      extensions = ["uuid-ossp" "citext" "moddatetime"];
    };
    ${db.nimbus.database} = {
      owner = db.nimbus.user;
      extensions = [];
    };
  };

  # Peer authentication over the socket for the server's own user only, which runs setup.
  hbaFile = pkgs.writeText "unison-cloud-pg_hba.conf" (
    ''
      local all ${user} peer
    ''
    + lib.concatStrings (lib.mapAttrsToList (name: database: ''
        host "${name}" "${database.owner}" 127.0.0.1/32 scram-sha-256
      '')
      databases)
  );
  roleSql = name: credential: ''
    SELECT format('CREATE ROLE %I', '${name}') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${name}') \gexec
    ALTER ROLE "${name}" LOGIN NOSUPERUSER NOCREATEROLE NOCREATEDB NOREPLICATION NOBYPASSRLS;
    \set password `${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/${credential}"`
    ALTER ROLE "${name}" PASSWORD :'password';
  '';
  databaseSql = name: database: ''
    SELECT format('CREATE DATABASE %I OWNER %I', '${name}', '${database.owner}') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${name}') \gexec
    REVOKE ALL ON DATABASE "${name}" FROM PUBLIC;
    \c "${name}"
    ${lib.concatMapStrings (ext: "CREATE EXTENSION IF NOT EXISTS \"${ext}\";\n") database.extensions}
  '';
  setupSql = pkgs.writeText "unison-cloud-postgresql-setup.sql" (
    lib.concatStrings (lib.mapAttrsToList roleSql roles)
    + lib.concatStrings (lib.mapAttrsToList databaseSql databases)
  );
in {
  options.services.unison-cloud.database = {
    host = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "127.0.0.1";
      description = ''
        Address of the PostgreSQL server. cloud-api and nimbus connect over TCP, each as
        its own role with a password, supplied as `cloud-api-db-password` and
        `nimbus-db-password` in `secrets.files` or `secrets.credentials`.
      '';
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
    };

    bundled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run a PostgreSQL server on loopback, with both roles and their databases, and
        generate their passwords.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.postgresql_17;
      defaultText = lib.literalExpression "pkgs.postgresql_17";
      description = ''
        PostgreSQL for the bundled server and the clients. Pin it: a major-version change
        starts an empty data directory, and moving data across needs a manual
        `pg_upgrade` or dump and restore.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = db.host != null;
          message = "services.unison-cloud: set database.host to the PostgreSQL server's address.";
        }
      ];

      systemd.services.unison-cloud-database = lib.mkMerge [
        cfg.internal.sandbox
        {
          description = "Wait for the Unison Cloud PostgreSQL server";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            DynamicUser = true;
            ExecStart = pkgs.writeShellScript "unison-cloud-database-wait" ''
              until ${pg}/bin/pg_isready -h ${lib.escapeShellArg db.host} -p ${toString db.port}; do sleep 1; done
            '';
            TimeoutStartSec = 300;
          };
        }
      ];
    }

    (lib.mkIf db.bundled {
      services.unison-cloud.database = {
        host = lib.mkDefault "127.0.0.1";
        port = lib.mkDefault 24150;
      };

      services.unison-cloud.internal.secretGenerators = lib.genAttrs (lib.attrValues roles) (_: "openssl rand -hex 24");

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
        cfg.internal.sandbox
        {
          description = "Unison Cloud bundled PostgreSQL";
          serviceConfig = {
            Type = "notify";
            User = user;
            Group = user;
            RuntimeDirectory = baseNameOf socketDir;
            RuntimeDirectoryMode = "0755";
            ExecStartPre = pkgs.writeShellScript "unison-cloud-postgresql-init" ''
              if [ ! -e ${dataDir}/PG_VERSION ]; then
                mkdir -p ${dataDir}
                ${pg}/bin/initdb -D ${dataDir} --auth-local=peer --auth-host=reject \
                  --encoding=UTF8 --locale=C --no-instructions
              fi
            '';
            # The module's own hba file replaces initdb's on every start.
            ExecStart = "${pg}/bin/postgres -D ${dataDir} -c listen_addresses=127.0.0.1 -c port=${toString db.port} -c unix_socket_directories=${socketDir} -c hba_file=${hbaFile}";
            ExecReload = "${lib.getExe' pkgs.coreutils "kill"} -HUP $MAINPID";
            KillMode = "mixed";
            KillSignal = "SIGINT";
            TimeoutSec = 120;
          };
        }
      ];

      systemd.services.unison-cloud-postgresql-setup = lib.mkMerge [
        cfg.internal.sandbox
        {
          description = "Create Unison Cloud database roles, databases and extensions";
          requires = ["unison-cloud-postgresql.service" "unison-cloud-secrets.service"];
          after = ["unison-cloud-postgresql.service" "unison-cloud-secrets.service"];
          serviceConfig = lib.mkMerge [
            (cfg.internal.loadSecrets (lib.attrValues roles))
            {
              Type = "oneshot";
              RemainAfterExit = true;
              User = user;
              Group = user;
              PrivateNetwork = true;
              ExecStart = "${pg}/bin/psql -h ${socketDir} -p ${toString db.port} -d postgres -X -v ON_ERROR_STOP=1 -f ${setupSql}";
            }
          ];
        }
      ];

      systemd.services.unison-cloud-database = {
        requires = ["unison-cloud-postgresql-setup.service"];
        after = ["unison-cloud-postgresql-setup.service"];
      };
    })
  ]);
}
