self: {
  lib,
  pkgs,
  ...
}: let
  packages = self.packages.${pkgs.stdenv.hostPlatform.system};
in {
  imports = [
    ./sandbox.nix
    ./secrets.nix
    ./ingress.nix
    ./dex.nix
    ./auth.nix
    ./caddy.nix
    ./postgresql.nix
    ./s3.nix
    ./consul.nix
    ./cloud-api.nix
    ./outbound-proxy.nix
    ./loki.nix
    ./nimbus.nix
  ];

  options.services.unison-cloud = {
    enable = lib.mkEnableOption "the self-hosted Unison Cloud stack";

    domains = lib.genAttrs ["api" "apps" "ui"] (name:
      lib.mkOption {
        type = lib.types.str;
        example = "${name}.example.com";
        description =
          {
            api = "Public hostname of cloud-api, which also serves login and the bundled Dex.";
            apps = "Public hostname of nimbus: the deploy API and every deployed service.";
            ui = "Public hostname of the cloud web UI.";
          }.${
            name
          };
      });

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/unison-cloud";
      description = "Directory holding generated secrets and the data of every bundled service.";
    };

    advertiseAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      example = "10.0.0.5";
      description = ''
        Address other hosts reach this host's cloud-api and nimbus nodes at. nimbus
        advertises it, cloud-api hands it to the cloud client for its TCP listener, and
        the Consul registrations carry it.
      '';
    };

    logs.lokiUrl = lib.mkOption {
      type = lib.types.str;
      example = "http://127.0.0.1:3100";
      description = ''
        Base URL of the Loki that Vector ships nimbus's logs to, and that cloud-api and
        nimbus query for a user's logs.
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

    nimbus.package = lib.mkOption {
      type = lib.types.package;
      default = packages.nimbus;
      defaultText = lib.literalExpression "self.packages.\${system}.nimbus";
      description = "Patched nimbus package, run once per node.";
    };
  };
}
