{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  db = cfg.database;
in {
  options.services.unison-cloud.database = {
    host = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "127.0.0.1";
      description = ''
        Address of the PostgreSQL server. cloud-api and nimbus connect over TCP, each as
        its own role with a password, supplied as `cloud-api-db-password` and
        `nimbus-db-password` in `secrets.files` or `secrets.credentials`. The module
        creates no roles or databases and never edits the server's configuration.
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
  };

  config = lib.mkIf cfg.enable {
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
            until ${pkgs.postgresql}/bin/pg_isready -h ${lib.escapeShellArg db.host} -p ${toString db.port}; do sleep 1; done
          '';
          TimeoutStartSec = 300;
        };
      }
    ];
  };
}
