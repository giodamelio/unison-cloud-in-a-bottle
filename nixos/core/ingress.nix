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

    caddy.siteConfig = lib.genAttrs ["api" "apps" "ui"] (name:
      lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        description =
          {
            api = ''
              Body of the API domain's Caddy site block. It sends `/login` to cloud-api's
              OIDC login, answers 404 for cloud-api's `/internal/*` routes, and proxies the
              rest to `ingress.upstreams.api`. cloud-api itself has no login other than
              OIDC, so these rules aren't what keeps it safe; it also drops client-sent
              `X-Auth-Request-*` headers, which nothing reads any more.

              For a monitor, `GET /.well-known/openid-configuration` needs no login and
              cloud-api answers it from memory, so a 200 means Caddy and cloud-api are
              up. It doesn't touch Postgres.
            '';
            apps = "Body of the apps domain's Caddy site block, balancing across the interactive nimbus nodes. Empty when nimbus is off.";
            ui = "Body of the UI domain's Caddy site block, serving `ui.package` as a single-page app.";
          }.${
            name
          };
      });

    ui.package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = cfg.internal.uiPackage.override {
        apiUrl = "${cfg.internal.publicUrl.api}/v2";
        websiteUrl = cfg.internal.publicUrl.ui;
        servicesUrl = "${cfg.internal.publicUrl.apps}/services";
      };
      defaultText = lib.literalMD "the cloud UI built for `domains.api`";
      description = "The cloud UI, built for this deployment's API origin. Serve it as a single-page app.";
    };

    internal.publicUrl = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      internal = true;
      readOnly = true;
      default = lib.mapAttrs (_: domain: "${cfg.ingress.scheme}://${domain}${portSuffix}") cfg.domains;
      description = "Public origin of each domain, with the scheme and any non-default port.";
    };
  };

  # Each body stands alone, with no global options or snippets, so any Caddy gets exactly
  # the same rules as the one in batteries.
  config.services.unison-cloud.caddy.siteConfig = {
    api = ''
      request_header -X-Auth-Request-*

      # The UI links to cloud-api's /login, which upstream sends to Share.
      handle /login {
        rewrite * /selfhost/oidc/login
        reverse_proxy ${cfg.ingress.upstreams.api}
      }

      # cloud-api's own health check and peer RPC; neither is for the public.
      handle /internal/* {
        respond 404
      }

      handle {
        reverse_proxy ${cfg.ingress.upstreams.api}
      }
    '';

    # Any interactive node can take any deploy and serve any service. The public port has
    # no health route, so failed nodes are skipped passively.
    apps = lib.optionalString (cfg.ingress.upstreams.apps != []) ''
      reverse_proxy ${lib.concatStringsSep " " cfg.ingress.upstreams.apps} {
        lb_policy round_robin
        lb_retries 2
        fail_duration 30s
      }
    '';

    ui = ''
      root * ${cfg.ui.package}
      try_files {path} /index.html
      file_server
      header X-Frame-Options DENY
    '';
  };

  config.assertions = lib.mkIf cfg.enable [
    {
      assertion = cfg.ingress.scheme == "https" || lib.all (lib.hasSuffix ".localhost") (lib.attrValues cfg.domains);
      message = "services.unison-cloud: ingress.scheme = \"http\" is only allowed when every domain ends in .localhost.";
    }
  ];
}
