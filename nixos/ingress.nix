{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  dir = "/run/unison-cloud";
  defaultPort =
    if cfg.ingress.scheme == "https"
    then 443
    else 80;
  portSuffix = lib.optionalString (cfg.ingress.port != null && cfg.ingress.port != defaultPort) ":${toString cfg.ingress.port}";
in {
  options.services.unison-cloud = {
    ingressGroup = lib.mkOption {
      type = lib.types.str;
      default = "caddy";
      description = ''
        Group that may open the ingress sockets under `${dir}/`.

        Members reach cloud-api and Dex without Caddy's rules in between. cloud-api has no
        route that logs anyone in without the OIDC login, so membership grants no identity,
        but it does reach `/internal/*`, which Caddy keeps private. Keep the group to the
        reverse proxy.
      '';
    };

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
    };

    internal.publicUrl = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      internal = true;
      readOnly = true;
      default = lib.mapAttrs (_: domain: "${cfg.ingress.scheme}://${domain}${portSuffix}") cfg.domains;
      description = "Public origin of each domain, with the scheme and any non-default port.";
    };

    internal.ingressSockets = lib.mkOption {
      type = lib.types.attrsOf lib.types.port;
      internal = true;
      default = {};
      description = "Ingress sockets `${dir}/<name>.sock`, each forwarded to that port on the namespace loopback.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.ingress.scheme == "https" || lib.all (lib.hasSuffix ".localhost") (lib.attrValues cfg.domains);
        message = "services.unison-cloud: ingress.scheme = \"http\" is only allowed when every domain ends in .localhost.";
      }
    ];

    users.groups.${cfg.ingressGroup} = {};

    # The directory's mode is the access control: only the ingress group can reach the sockets.
    systemd.tmpfiles.settings.unison-cloud-ingress.${dir}.d = {
      user = "root";
      group = cfg.ingressGroup;
      mode = "0750";
    };

    systemd.sockets = lib.mapAttrs' (name: _:
      lib.nameValuePair "unison-cloud-ingress-${name}" {
        description = "Unison Cloud ingress socket for ${name}";
        wantedBy = ["sockets.target"];
        socketConfig = {
          ListenStream = "${dir}/${name}.sock";
          SocketGroup = cfg.ingressGroup;
          SocketMode = "0660";
        };
      })
    cfg.internal.ingressSockets;

    systemd.services = lib.mapAttrs' (name: port:
      lib.nameValuePair "unison-cloud-ingress-${name}" (lib.mkMerge [
        cfg.internal.inNamespace
        {
          description = "Forward the ${name} ingress socket into the Unison Cloud namespace";
          requires = ["unison-cloud-ingress-${name}.socket"];
          after = ["unison-cloud-ingress-${name}.socket"];
          serviceConfig = {
            ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd 127.0.0.1:${toString port}";
            DynamicUser = true;
            PrivateTmp = true;
          };
        }
      ]))
    cfg.internal.ingressSockets;
  };
}
