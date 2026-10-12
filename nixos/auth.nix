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
  bridged = !dex.enable && oidc.bridge.target != null;
  bridgeOrigin = "http://127.0.0.1:${toString cfg.internal.oidcBridgePort}";
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
            default =
              if name != "authorization" && oidc.bridge.target != null && oidc.bridge."${name}Path" != null
              then "${bridgeOrigin}${oidc.bridge."${name}Path"}"
              else null;
            defaultText = lib.literalMD (
              if name == "authorization"
              then "`null`"
              else "`http://127.0.0.1:<bridge port><bridge.${name}Path>` with `bridge.target` set, otherwise `null`"
            );
            description =
              {
                authorization = "The provider's authorization endpoint. The browser follows it, so it must be the public URL.";
                token = "The token endpoint cloud-api exchanges codes at.";
                jwks = "The JWKS URL cloud-api fetches the provider's signing keys from.";
              }.${
                name
              }
              + " Set all three or none; with none, cloud-api reads them from the issuer's discovery document.";
          });

        bridge = {
          target = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "127.0.0.1:1411";
            description = ''
              Reach the provider's token and JWKS endpoints through a host bridge (see
              `network.hostBridges`) that only cloud-api may use, instead of letting cloud-api
              send traffic out of the namespace. The target is the provider's plain-HTTP
              listener on the host, `host:port` or a unix socket path. Set
              `endpoints.authorization` to the public URL, and `tokenPath` and `jwksPath`.
            '';
          };

          tokenPath = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "/api/oidc/token";
            description = "Path of the token endpoint on the bridge target.";
          };

          jwksPath = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "/.well-known/jwks.json";
            description = "Path of the JWKS document on the bridge target.";
          };
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

      oidcBridgePort = lib.mkOption {
        type = lib.types.port;
        internal = true;
        readOnly = true;
        default = 5427;
        description = "Port of the login provider's bridge, on the namespace loopback.";
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

  config = lib.mkIf cfg.enable {
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
        assertion = !dex.enable || (oidc.bridge.target == null && lib.all (e: e == null) endpoints);
        message = "services.unison-cloud: auth.oidc.endpoints and auth.oidc.bridge are for an external provider; set auth.dex.enable = false to use them.";
      }
      {
        assertion = fixedEndpoints || lib.all (e: e == null) endpoints;
        message = "services.unison-cloud: set all of auth.oidc.endpoints.authorization, token and jwks, or none.";
      }
      {
        assertion = oidc.bridge.target == null || (oidc.bridge.tokenPath != null && oidc.bridge.jwksPath != null && oidc.endpoints.authorization != null);
        message = "services.unison-cloud: with auth.oidc.bridge.target set, also set bridge.tokenPath, bridge.jwksPath and endpoints.authorization.";
      }
    ];

    # cloud-api is the OIDC client (cloud-api patch 0007): it runs the login against the
    # provider, provisions the user, and serves ucm's authorization endpoints itself.
    # Without a bridge, an external provider is out on the network, which only egress
    # users may reach.
    services.unison-cloud.internal.egressUsers = lib.mkIf (!dex.enable && !bridged) ["unison-cloud-api"];

    services.unison-cloud.network.hostBridges.oidc = lib.mkIf bridged {
      inherit (oidc.bridge) target;
      port = cfg.internal.oidcBridgePort;
      users = ["unison-cloud-api"];
    };

    systemd.services.unison-cloud-api = {
      requires = lib.optional dex.enable "unison-cloud-dex.service" ++ lib.optional bridged "unison-cloud-bridge-oidc.socket";
      after = lib.optional dex.enable "unison-cloud-dex.service" ++ lib.optional bridged "unison-cloud-bridge-oidc.socket";
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
        # namespace. cloud-api still validates tokens against that issuer, but makes its
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
