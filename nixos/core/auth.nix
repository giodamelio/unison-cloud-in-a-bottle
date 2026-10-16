{
  config,
  lib,
  ...
}: let
  cfg = config.services.unison-cloud;
  oidc = cfg.auth.oidc;
  endpoints = lib.attrValues oidc.endpoints;
  fixedEndpoints = lib.all (e: e != null) endpoints;

  allowlisted = oidc.allowedEmails != [] || oidc.allowedEmailDomains != [] || oidc.allowedGroups != [];
  commaList = lib.concatStringsSep ",";
in {
  options.services.unison-cloud.auth = {
    oidc = {
      issuer = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://login.example.com";
        description = ''
          Issuer of the OIDC provider users log in through. cloud-api compares it verbatim
          with every ID token's `iss`, wherever it fetched the token from, and records
          identities against it.
        '';
      };

      clientId = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Confidential client at the provider, whose redirect URI is
          `<public API URL>/selfhost/oidc/callback`. Supply its secret as
          `oidc-client-secret` in `secrets.files` or `secrets.credentials`.
        '';
      };

      endpoints = lib.genAttrs ["authorization" "token" "jwks"] (name:
        lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example =
            {
              authorization = "https://login.example.com/authorize";
              token = "http://127.0.0.1:1411/api/oidc/token";
              jwks = "http://127.0.0.1:1411/.well-known/jwks.json";
            }.${
              name
            };
          description =
            {
              authorization = "The provider's authorization endpoint. The browser follows it, so it must be the public URL.";
              token = "The token endpoint cloud-api exchanges codes at, such as the provider's own listener on this host.";
              jwks = "The JWKS URL cloud-api fetches the provider's signing keys from, such as the provider's own listener on this host.";
            }.${
              name
            }
            + " Set all three or none; with none, cloud-api reads them from the issuer's discovery document.";
        });

      allowedEmails = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Verified email addresses that may log in.";
      };

      allowedEmailDomains = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Email domains whose verified addresses may log in.";
      };

      allowedGroups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Groups (from the provider's `groups` claim) whose members may log in.";
      };
    };

    defaultTier = lib.mkOption {
      type = lib.types.enum ["free" "starter"];
      default = "free";
      description = "Tier given to every user on login. `starter` adds custom domains.";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.cloudApi.enable) {
    assertions = [
      {
        assertion = oidc.issuer != null && oidc.clientId != null;
        message = "services.unison-cloud: set auth.oidc.issuer and clientId.";
      }
      {
        assertion = allowlisted;
        message = "services.unison-cloud: set at least one of auth.oidc.allowedEmails, allowedEmailDomains or allowedGroups.";
      }
      {
        assertion = fixedEndpoints || lib.all (e: e == null) endpoints;
        message = "services.unison-cloud: set all of auth.oidc.endpoints.authorization, token and jwks, or none.";
      }
    ];

    # cloud-api is the OIDC client (cloud-api patch 0007): it runs the login against the
    # provider, provisions the user, and serves ucm's authorization endpoints itself.
    systemd.services.unison-cloud-api.environment =
      {
        CLOUD_OIDC_ISSUER = oidc.issuer;
        CLOUD_OIDC_CLIENT_ID = oidc.clientId;
      }
      // lib.optionalAttrs (oidc.allowedEmails != []) {CLOUD_OIDC_ALLOWED_EMAILS = commaList oidc.allowedEmails;}
      // lib.optionalAttrs (oidc.allowedEmailDomains != []) {CLOUD_OIDC_ALLOWED_EMAIL_DOMAINS = commaList oidc.allowedEmailDomains;}
      // lib.optionalAttrs (oidc.allowedGroups != []) {CLOUD_OIDC_ALLOWED_GROUPS = commaList oidc.allowedGroups;}
      # The issuer is a public URL that may not resolve, or may be firewalled, from this
      # host. cloud-api still validates tokens against that issuer, but makes its
      # server-to-server calls to the configured endpoints.
      // lib.optionalAttrs fixedEndpoints {
        CLOUD_OIDC_AUTHORIZATION_URL = oidc.endpoints.authorization;
        CLOUD_OIDC_TOKEN_URL = oidc.endpoints.token;
        CLOUD_OIDC_JWKS_URL = oidc.endpoints.jwks;
      };
  };
}
