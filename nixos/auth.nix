{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  oidc = cfg.auth.oidc;
  dex = cfg.auth.dex;
  secrets = "${cfg.stateDir}/secrets";
  apiOrigin = cfg.internal.publicUrl.api;
  dexLoopback = "http://127.0.0.1:${toString cfg.internal.dexPort}/dex";

  allowlisted = oidc.allowedEmails != [] || oidc.allowedEmailDomains != [] || oidc.allowedGroups != [];
  emailsFile = pkgs.writeText "unison-cloud-allowed-emails" (lib.concatLines oidc.allowedEmails);

  # The issuer is a public URL that may not resolve, or may be firewalled, inside the
  # namespace. With the bundled Dex, oauth2-proxy validates tokens against that issuer
  # but makes its server-to-server calls to Dex's loopback listener.
  providerFlags =
    if dex.enable
    then [
      "--skip-oidc-discovery"
      "--login-url=${cfg.internal.oidcIssuer}/auth"
      "--redeem-url=${dexLoopback}/token"
      "--oidc-jwks-url=${dexLoopback}/keys"
      "--client-id=oauth2-proxy"
      "--client-secret-file=%d/client-secret"
    ]
    else [
      "--client-id=${oidc.clientId}"
      "--client-secret-file=%d/client-secret"
    ];

  allowFlags =
    lib.optional (oidc.allowedEmails != []) "--authenticated-emails-file=${emailsFile}"
    ++ map (d: "--email-domain=${d}") oidc.allowedEmailDomains
    ++ map (g: "--allowed-group=${g}") oidc.allowedGroups
    # Only declared users exist in the bundled Dex, so with no allowlist every one of them may log in.
    ++ lib.optional (dex.enable && !allowlisted) "--email-domain=*";
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
          description = "Client ID at the external provider, whose redirect URI is `https://<domains.api>/oauth2/callback`.";
        };

        clientSecretFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "File holding the external provider's client secret.";
        };

        allowedEmails = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Email addresses that may log in.";
        };

        allowedEmailDomains = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Email domains whose addresses may log in.";
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

      oauth2ProxyPort = lib.mkOption {
        type = lib.types.port;
        internal = true;
        readOnly = true;
        default = 4180;
        description = "oauth2-proxy's port on the namespace loopback.";
      };
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

    services.unison-cloud.internal.ingressSockets.oauth2-proxy = cfg.internal.oauth2ProxyPort;

    systemd.services.unison-cloud-oauth2-proxy = lib.mkMerge [
      cfg.internal.inNamespace
      {
        description = "Unison Cloud login front (oauth2-proxy)";
        wantedBy = ["multi-user.target"];
        requires = ["unison-cloud-secrets.service"] ++ lib.optional dex.enable "unison-cloud-dex.service";
        after = ["unison-cloud-secrets.service"] ++ lib.optional dex.enable "unison-cloud-dex.service";
        serviceConfig = {
          DynamicUser = true;
          LoadCredential = [
            "client-secret:${
              if dex.enable
              then "${secrets}/dex-client-secret"
              else oidc.clientSecretFile
            }"
            "cookie-secret:${secrets}/oauth2-proxy-cookie-secret"
          ];
          ExecStart = lib.escapeShellArgs ([
              (lib.getExe pkgs.oauth2-proxy)
              "--http-address=127.0.0.1:${toString cfg.internal.oauth2ProxyPort}"
              "--provider=oidc"
              "--oidc-issuer-url=${cfg.internal.oidcIssuer}"
              "--redirect-url=${apiOrigin}/oauth2/callback"
              "--scope=openid email profile"
              "--code-challenge-method=S256"
              "--cookie-secret-file=%d/cookie-secret"
              "--cookie-secure=${lib.boolToString (cfg.ingress.scheme == "https")}"
              "--set-xauthrequest"
              "--skip-provider-button"
              # The default, "force", makes Dex show its consent screen on every login.
              "--approval-prompt=auto"
              "--reverse-proxy"
              # The ingress socket proxy connects from the namespace loopback.
              "--trusted-proxy-ip=127.0.0.1/32"
              "--whitelist-domain=${cfg.domains.api}:*"
              # Requests only reach oauth2-proxy for forward_auth and its own /oauth2 routes.
              "--upstream=static://202"
            ]
            ++ providerFlags
            ++ allowFlags);
        };
      }
    ];
  };
}
