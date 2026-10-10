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
    ./egress.nix
    ./secrets.nix
    ./ingress.nix
    ./dex.nix
    ./auth.nix
    ./caddy.nix
    ./postgresql.nix
    ./extenddb.nix
    ./s3.nix
    ./redis.nix
    ./consul.nix
    ./cloud-api.nix
    ./outbound-proxy.nix
  ];

  options.services.unison-cloud = {
    enable = lib.mkEnableOption "the self-hosted Unison Cloud stack";

    domains = lib.genAttrs ["api" "apps" "ui"] (name:
      lib.mkOption {
        type = lib.types.str;
        example = "${name}.example.com";
        description = {
          api = "Public hostname of cloud-api, which also serves login and the bundled Dex.";
          apps = "Public hostname of nimbus: the deploy API and every deployed service.";
          ui = "Public hostname of the cloud web UI.";
        }.${name};
      });

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

    internal.uiPackage = lib.mkOption {
      type = lib.types.package;
      internal = true;
      default = packages.unison-cloud-ui;
      description = "The cloud UI package before it's built for this deployment's domains.";
    };

    cloudApi.package = lib.mkOption {
      type = lib.types.package;
      default = packages.cloud-api;
      defaultText = lib.literalExpression "self.packages.\${system}.cloud-api";
      description = "Patched cloud-api package. Its `sql` passthru holds the migrations.";
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
