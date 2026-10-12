{
  config,
  lib,
  ...
}: let
  cfg = config.services.unison-cloud;
  sock = name: "unix//run/unison-cloud/${name}.sock";
  appsSockets = lib.filter (lib.hasPrefix "nimbus-interactive-") (lib.attrNames cfg.internal.ingressSockets);
in {
  options.services.unison-cloud = {
    caddy = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Serve the API, apps and UI domains through `services.caddy`. With `false`, serve
          them from your own Caddy by using `caddy.siteConfig` as each site block's body.
        '';
      };

      siteConfig = lib.genAttrs ["api" "apps" "ui"] (name:
        lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          description =
            {
              api = ''
                Body of the API domain's Caddy site block. It drops client-sent
                `X-Auth-Request-*` headers, sends `/login` to cloud-api's OIDC login,
                answers 404 for the routes that trust identity headers or are internal,
                and proxies the rest to cloud-api's ingress socket.

                For a monitor, `GET /.well-known/openid-configuration` needs no login and
                cloud-api answers it from memory, so a 200 means Caddy, the socket and
                cloud-api are up. It doesn't touch Postgres or Redis.
              '';
              apps = "Body of the apps domain's Caddy site block, balancing across the interactive nimbus nodes. Empty when nimbus is off.";
              ui = "Body of the UI domain's Caddy site block, serving `ui.package` as a single-page app.";
            }.${
              name
            };
        });
    };

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
  };

  # Each body stands alone, with no global options or snippets, so a Caddy outside this
  # module gets exactly the same rules as the bundled one.
  config.services.unison-cloud.caddy.siteConfig = {
    api = ''
      request_header -X-Auth-Request-*

      ${lib.optionalString cfg.auth.dex.enable ''
        handle /dex/* {
          reverse_proxy ${sock "dex"}
        }
      ''}
      # The UI links to cloud-api's /login, which upstream sends to Share.
      handle /login {
        rewrite * /selfhost/oidc/login
        reverse_proxy ${sock "cloud-api"}
      }

      # The header-trust login routes would believe any X-Auth-Request-* header, and
      # nothing in front of them vouches for one, so they stay unreachable.
      @blocked path /oauth/* /oauth2/* /enroll* /local/* /internal/* /selfhost/login /selfhost/access-token
      handle @blocked {
        respond 404
      }

      handle {
        reverse_proxy ${sock "cloud-api"}
      }
    '';

    # Any interactive node can take any deploy and serve any service. The public port has
    # no health route, so failed nodes are skipped passively.
    apps = lib.optionalString (appsSockets != []) ''
      reverse_proxy ${lib.concatMapStringsSep " " sock appsSockets} {
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

  config.services.caddy = lib.mkIf (cfg.enable && cfg.caddy.enable) {
    enable = true;
    virtualHosts =
      {
        ${cfg.internal.publicUrl.api}.extraConfig = cfg.caddy.siteConfig.api;
        ${cfg.internal.publicUrl.ui}.extraConfig = cfg.caddy.siteConfig.ui;
      }
      // lib.optionalAttrs (cfg.caddy.siteConfig.apps != "") {
        ${cfg.internal.publicUrl.apps}.extraConfig = cfg.caddy.siteConfig.apps;
      };
  };
}
