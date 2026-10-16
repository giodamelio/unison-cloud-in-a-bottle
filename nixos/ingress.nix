{
  config,
  lib,
  ...
}: let
  cfg = config.services.unison-cloud;
  defaultPort =
    if cfg.ingress.scheme == "https"
    then 443
    else 80;
  portSuffix = lib.optionalString (cfg.ingress.port != null && cfg.ingress.port != defaultPort) ":${toString cfg.ingress.port}";
in {
  options.services.unison-cloud = {
    ingress = {
      scheme = lib.mkOption {
        type = lib.types.enum ["https" "http"];
        default = "https";
        description = ''
          Scheme of every public URL. `http` is only allowed when all three domains end in
          `.localhost`, which browsers treat as a secure context; it exists for the demo VM.
        '';
      };

      port = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = "Port of every public URL, and the port Caddy listens on. `null` means the scheme's default.";
      };

      upstreams = {
        api = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = "127.0.0.1:${toString cfg.cloudApi.port}";
          description = "Where a reverse proxy on this host sends the API domain: cloud-api's HTTP port.";
        };

        apps = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          readOnly = true;
          default =
            lib.optionals cfg.nimbus.enable (map (node: "127.0.0.1:${toString node.ports.publicHttp}")
              (lib.filter (node: node.type == "interactive") cfg.internal.nimbusNodes));
          description = "Where a reverse proxy on this host balances the apps domain: the public port of every interactive nimbus node. Empty when nimbus is off.";
        };
      };
    };

    internal.publicUrl = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      internal = true;
      readOnly = true;
      default = lib.mapAttrs (_: domain: "${cfg.ingress.scheme}://${domain}${portSuffix}") cfg.domains;
      description = "Public origin of each domain, with the scheme and any non-default port.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.ingress.scheme == "https" || lib.all (lib.hasSuffix ".localhost") (lib.attrValues cfg.domains);
        message = "services.unison-cloud: ingress.scheme = \"http\" is only allowed when every domain ends in .localhost.";
      }
    ];
  };
}
