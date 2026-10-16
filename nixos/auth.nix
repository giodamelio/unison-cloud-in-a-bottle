{
  config,
  lib,
  ...
}: let
  cfg = config.services.unison-cloud;
  oidc = cfg.auth.oidc;
  dex = cfg.auth.dex;
  apiOrigin = cfg.internal.publicUrl.api;
  dexLoopback = "http://127.0.0.1:${toString cfg.internal.dexPort}/dex";
  endpoints = lib.attrValues oidc.endpoints;
  fixedEndpoints = lib.all (e: e != null) endpoints;

  allowlisted = oidc.allowedEmails != [] || oidc.allowedEmailDomains != [] || oidc.allowedGroups != [];
  commaList = lib.concatStringsSep ",";
in {
  options.services.unison-cloud = {
    auth = {
      oidc = {
        issuer = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "https://login.example.com";
          description = ''
            Issuer of an external OIDC provider. Required when `auth.dex.enable = false`.
            cloud-api compares it verbatim with every ID token's `iss`, wherever it fetched
            the token from.
          '';
        };

        clientId = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Confidential client at the external provider, whose redirect URI is `<public API URL>/selfhost/oidc/callback`.";
        };

        clientSecretFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "File holding the external provider's client secret. A string, so the secret never enters the Nix store.";
        };

        clientSecretCredential = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "unison-cloud-oidc-client-secret";
          description = ''
            The external provider's client secret as a systemd encrypted credential: a name
            in `/etc/credstore.encrypted/` or an absolute path. systemd checks the name
            embedded in it, so encrypt it with `systemd-creds encrypt --name=oidc-client-secret`.
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

    internal = {
      oidcIssuer = lib.mkOption {
        type = lib.types.str;
        internal = true;
        readOnly = true;
        default =
          if dex.enable
          then "${apiOrigin}/dex"
          else oidc.issuer;
        defaultText = lib.literalMD "the bundled Dex's issuer, or `auth.oidc.issuer`";
        description = "Issuer users log in through; cloud-api records identities against it.";
      };

      oidcSecretCredential = lib.mkOption {
        type = lib.types.str;
        internal = true;
        readOnly = true;
        default =
          if dex.enable
          then "dex-client-secret"
          else "oidc-client-secret";
        description = "Name of the credential cloud-api reads its OIDC client secret from.";
      };
    };
  };

  config = lib.mkIf (cfg.enable && cfg.cloudApi.enable) {
    assertions = [
      {
        assertion = dex.enable || (oidc.issuer != null && oidc.clientId != null);
        message = "services.unison-cloud: with auth.dex.enable = false, set auth.oidc.issuer and clientId.";
      }
      {
        assertion = dex.enable || lib.count (s: s != null) [oidc.clientSecretFile oidc.clientSecretCredential] == 1;
        message = "services.unison-cloud: with auth.dex.enable = false, set exactly one of auth.oidc.clientSecretFile and clientSecretCredential.";
      }
      {
        assertion = dex.enable || allowlisted;
        message = "services.unison-cloud: with an external OIDC provider, set at least one of auth.oidc.allowedEmails, allowedEmailDomains or allowedGroups.";
      }
      {
        assertion = !dex.enable || lib.all (e: e == null) endpoints;
        message = "services.unison-cloud: auth.oidc.endpoints are for an external provider; set auth.dex.enable = false to use them.";
      }
      {
        assertion = fixedEndpoints || lib.all (e: e == null) endpoints;
        message = "services.unison-cloud: set all of auth.oidc.endpoints.authorization, token and jwks, or none.";
      }
    ];

    # cloud-api is the OIDC client (cloud-api patch 0007): it runs the login against the
    # provider, provisions the user, and serves ucm's authorization endpoints itself.
    systemd.services.unison-cloud-api = {
      requires = lib.optional dex.enable "unison-cloud-dex.service";
      after = lib.optional dex.enable "unison-cloud-dex.service";
      environment =
        {
          CLOUD_OIDC_ISSUER = cfg.internal.oidcIssuer;
          CLOUD_OIDC_CLIENT_ID =
            if dex.enable
            then "cloud-api"
            else oidc.clientId;
        }
        # An unset list doesn't restrict; only declared users exist in the bundled Dex.
        // lib.optionalAttrs (oidc.allowedEmails != []) {CLOUD_OIDC_ALLOWED_EMAILS = commaList oidc.allowedEmails;}
        // lib.optionalAttrs (oidc.allowedEmailDomains != []) {CLOUD_OIDC_ALLOWED_EMAIL_DOMAINS = commaList oidc.allowedEmailDomains;}
        // lib.optionalAttrs (oidc.allowedGroups != []) {CLOUD_OIDC_ALLOWED_GROUPS = commaList oidc.allowedGroups;}
        # The issuer is a public URL that may not resolve, or may be firewalled, from this
        # host. cloud-api still validates tokens against that issuer, but makes its
        # server-to-server calls to Dex's loopback listener, or to the configured endpoints.
        // lib.optionalAttrs dex.enable {
          CLOUD_OIDC_AUTHORIZATION_URL = "${cfg.internal.oidcIssuer}/auth";
          CLOUD_OIDC_TOKEN_URL = "${dexLoopback}/token";
          CLOUD_OIDC_JWKS_URL = "${dexLoopback}/keys";
        }
        // lib.optionalAttrs (!dex.enable && fixedEndpoints) {
          CLOUD_OIDC_AUTHORIZATION_URL = oidc.endpoints.authorization;
          CLOUD_OIDC_TOKEN_URL = oidc.endpoints.token;
          CLOUD_OIDC_JWKS_URL = oidc.endpoints.jwks;
        };
      serviceConfig =
        if dex.enable
        then cfg.internal.loadSecrets ["dex-client-secret"]
        else if oidc.clientSecretCredential != null
        then {LoadCredentialEncrypted = ["oidc-client-secret:${oidc.clientSecretCredential}"];}
        else {LoadCredential = lib.optional (oidc.clientSecretFile != null) "oidc-client-secret:${oidc.clientSecretFile}";};
    };
  };
}
