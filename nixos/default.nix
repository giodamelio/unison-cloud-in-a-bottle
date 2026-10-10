self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  packages = self.packages.${pkgs.stdenv.hostPlatform.system};
in {
  imports = [
    ./netns.nix
    ./secrets.nix
    ./postgresql.nix
    ./extenddb.nix
  ];

  options.services.unison-cloud = {
    enable = lib.mkEnableOption "the self-hosted Unison Cloud stack";

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/unison-cloud";
      description = "Directory holding generated secrets and the data of every bundled service.";
    };

    network.namespace = lib.mkOption {
      type = lib.types.str;
      default = "unison-cloud";
      description = "Name of the private network namespace the services run in.";
    };

    database.package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.postgresql_17;
      defaultText = lib.literalExpression "pkgs.postgresql_17";
      description = ''
        PostgreSQL server for the bundled database. Pin it: a major-version change starts
        an empty data directory, and moving data across needs a manual `pg_upgrade` or
        dump and restore.
      '';
    };

    extenddb = {
      package = lib.mkOption {
        type = lib.types.package;
        default = packages.extenddb;
        defaultText = lib.literalExpression "self.packages.\${system}.extenddb";
        description = "ExtendDB package, the DynamoDB-compatible store nimbus uses.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 18443;
        description = "HTTPS port ExtendDB listens on, on the namespace loopback.";
      };

      tableName = lib.mkOption {
        type = lib.types.str;
        default = "unison-cloud";
        description = "Name of the DynamoDB table nimbus stores transactional data in.";
      };
    };
  };
}
