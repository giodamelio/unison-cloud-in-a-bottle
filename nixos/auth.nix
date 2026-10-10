{
  config,
  lib,
  ...
}: let
  cfg = config.services.unison-cloud;
  oidc = cfg.auth.oidc;
  dex = cfg.auth.dex;
  secrets = "${cfg.stateDir}/secrets";
  apiOrigin = cfg.internal.publicUrl.api;
  dexLoopback = "http://127.0.0.1:${toString cfg.internal.dexPort}/dex";

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
          description = "Issuer of an external OIDC provider. Required when `auth.dex.enable = false`.";
        };

        clientId = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Confidential client at the external provider, whose redirect URI is `<public API URL>/selfhost/oidc/callback`.";
        };

        clientSecretFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "File holding the external provider's client secret.";
        };

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

    internal.oidcIssuer = lib.mkOption {
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
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = dex.enable || (oidc.issuer != null && oidc.clientId != null && oidc.clientSecretFile != null);
        message = "services.unison-cloud: with auth.dex.enable = false, set auth.oidc.issuer, clientId and clientSecretFile.";
      }
      {
        assertion = dex.enable || allowlisted;
        message = "services.unison-cloud: with an external OIDC provider, set at least one of auth.oidc.allowedEmails, allowedEmailDomains or allowedGroups.";
      }
    ];

    # cloud-api is the OIDC client (cloud-api patch 0008): it runs the login against the
    # provider, provisions the user, and serves ucm's authorization endpoints itself.
    # An external provider is on the internet, which only egress users may reach.
    services.unison-cloud.internal.egressUsers = lib.mkIf (!dex.enable) ["unison-cloud-api"];

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
        # The issuer is a public URL that may not resolve, or may be firewalled, inside the
        # namespace. With the bundled Dex, cloud-api validates tokens against that issuer
        # but makes its server-to-server calls to Dex's loopback listener.
        // lib.optionalAttrs dex.enable {
          CLOUD_OIDC_AUTHORIZATION_URL = "${cfg.internal.oidcIssuer}/auth";
          CLOUD_OIDC_TOKEN_URL = "${dexLoopback}/token";
          CLOUD_OIDC_JWKS_URL = "${dexLoopback}/keys";
        };
      serviceConfig.LoadCredential = [
        "oidc-client-secret:${
          if dex.enable
          then "${secrets}/dex-client-secret"
          else oidc.clientSecretFile
        }"
      ];
    };
  };
}
