{
  config,
  lib,
  ...
}: let
  cfg = config.services.unison-cloud;
  sock = name: "unix//run/unison-cloud/${name}.sock";
in {
  options.services.unison-cloud = {
    caddy.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Serve the API and UI domains through `services.caddy`. With `false`, route to the
        sockets under `/run/unison-cloud/` yourself, applying the same rules: strip
        client-sent `X-Auth-Request-*` headers, gate the login routes with oauth2-proxy,
        and refuse `/oauth/*`, `/enroll*`, `/local/*` and `/internal/*`.
      '';
    };

    ui.package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = cfg.internal.uiPackage.override {
        apiUrl = "${cfg.internal.publicUrl.api}/v2";
        websiteUrl = cfg.internal.publicUrl.ui;
      };
      defaultText = lib.literalMD "the cloud UI built for `domains.api`";
      description = "The cloud UI, built for this deployment's API origin. Serve it as a single-page app.";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.caddy.enable) {
    services.caddy = {
      enable = true;

      virtualHosts.${cfg.internal.publicUrl.api}.extraConfig = ''
        request_header -X-Auth-Request-*

        ${lib.optionalString cfg.auth.dex.enable ''
          handle /dex/* {
            reverse_proxy ${sock "dex"}
          }
        ''}
        handle /oauth2/* {
          reverse_proxy ${sock "oauth2-proxy"}
        }

        @login path /login /selfhost/login /selfhost/access-token
        handle @login {
          forward_auth ${sock "oauth2-proxy"} {
            uri /oauth2/auth
            copy_headers X-Auth-Request-User X-Auth-Request-Email X-Auth-Request-Preferred-Username
            @unauthed status 401
            handle_response @unauthed {
              redir * /oauth2/start?rd={scheme}://{hostport}{uri}
            }
          }
          rewrite /login /selfhost/login
          reverse_proxy ${sock "cloud-api"}
        }

        @blocked path /oauth/* /enroll* /local/* /internal/*
        handle @blocked {
          respond 404
        }

        handle {
          reverse_proxy ${sock "cloud-api"}
        }
      '';

      virtualHosts.${cfg.internal.publicUrl.ui}.extraConfig = ''
        root * ${cfg.ui.package}
        try_files {path} /index.html
        file_server
        header X-Frame-Options DENY
      '';
    };
  };
}
