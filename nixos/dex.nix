{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  dex = cfg.auth.dex;
  user = "unison-cloud-dex";
  dataDir = "${cfg.stateDir}/dex";
  secrets = "${cfg.stateDir}/secrets";
  runtimeDir = "/run/unison-cloud-dex";
  issuer = cfg.internal.oidcIssuer;

  baseConfig = pkgs.writeText "unison-cloud-dex-base.json" (builtins.toJSON {
    inherit issuer;
    storage = {
      type = "sqlite3";
      config.file = "${dataDir}/dex.sqlite";
    };
    web.http = "127.0.0.1:${toString cfg.internal.dexPort}";
    enablePasswordDB = true;
    oauth2.skipApprovalScreen = true;
  });

  users =
    lib.optional dex.adminUser.enable {
      email = "admin@${cfg.domains.api}";
      username = "admin";
      passwordHashFile = "${runtimeDir}/admin.bcrypt";
    }
    ++ dex.users;

  # Dex's config holds runtime-generated secrets, so it's assembled at start rather than in the store.
  render = pkgs.writeShellApplication {
    name = "unison-cloud-dex-render";
    runtimeInputs = [pkgs.jq pkgs.util-linux pkgs.coreutils pkgs.mkpasswd];
    text = ''
      umask 077
      ${lib.optionalString dex.adminUser.enable ''
        mkpasswd -m bcrypt -R 10 -s < ${secrets}/dex-admin-password > ${runtimeDir}/admin.bcrypt
      ''}
      passwords='[]'
      ${lib.concatMapStrings (u: ''
          # The sub claim Dex issues comes from userID, so derive it from the email: the
          # same email always maps to the same cloud-api account.
          passwords=$(jq -c \
            --arg email ${lib.escapeShellArg u.email} \
            --arg username ${lib.escapeShellArg u.username} \
            --arg hash "$(< ${lib.escapeShellArg u.passwordHashFile})" \
            --arg userID "$(uuidgen --sha1 --namespace @url --name ${lib.escapeShellArg "mailto:${u.email}"})" \
            '. + [{email: $email, username: $username, preferredUsername: $username, hash: $hash, userID: $userID}]' \
            <<< "$passwords")
        '')
        users}
      jq \
        --argjson passwords "$passwords" \
        --arg secret "$(< /run/credentials/unison-cloud-dex.service/oidc-client-secret)" \
        '. + {staticPasswords: $passwords, staticClients: [{
          id: "cloud-api",
          name: "Unison Cloud",
          secret: $secret,
          redirectURIs: ["${cfg.internal.publicUrl.api}/selfhost/oidc/callback"]
        }]}' \
        ${baseConfig} > ${runtimeDir}/config.json
      chown ${user}:${user} ${runtimeDir}/config.json
      chmod 0400 ${runtimeDir}/config.json
    '';
  };
in {
  options.services.unison-cloud = {
    auth.dex = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run the bundled Dex at `https://<domains.api>/dex` as the login provider.";
      };

      users = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            email = lib.mkOption {type = lib.types.str;};
            username = lib.mkOption {
              type = lib.types.str;
              description = "Becomes the cloud-api handle on first login.";
            };
            passwordHashFile = lib.mkOption {
              type = lib.types.str;
              description = ''
                File holding a bcrypt hash of the password, for example from `mkpasswd -m bcrypt`.
                A string, so the hash never enters the Nix store.
              '';
            };
          };
        });
        default = [];
        description = "Users of the bundled Dex's password database.";
      };

      adminUser.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Create user `admin` (email `admin@<domains.api>`) with a password generated on
          first start and written to `<stateDir>/secrets/dex-admin-password`.
        '';
      };
    };

    internal.dexPort = lib.mkOption {
      type = lib.types.port;
      internal = true;
      readOnly = true;
      default = 24154;
      description = "Dex's plain HTTP port on loopback; TLS is the reverse proxy's job.";
    };
  };

  config = lib.mkIf (cfg.enable && dex.enable) {
    users.users.${user} = {
      isSystemUser = true;
      group = user;
    };
    users.groups.${user} = {};

    services.unison-cloud.internal.secretGenerators =
      {oidc-client-secret = "openssl rand -hex 32";}
      // lib.optionalAttrs dex.adminUser.enable {dex-admin-password = "openssl rand -hex 16";};

    systemd.tmpfiles.settings.unison-cloud-dex.${dataDir}.d = {
      inherit user;
      group = user;
      mode = "0700";
    };

    systemd.services.unison-cloud-dex = lib.mkMerge [
      cfg.internal.sandbox
      {
        description = "Unison Cloud login provider (Dex)";
        wantedBy = ["multi-user.target"];
        requires = ["unison-cloud-secrets.service"];
        after = ["unison-cloud-secrets.service"];
        restartTriggers = [baseConfig];
        serviceConfig = lib.mkMerge [
          (cfg.internal.loadSecrets ["oidc-client-secret"])
          {
            User = user;
            Group = user;
            RuntimeDirectory = baseNameOf runtimeDir;
            RuntimeDirectoryMode = "0700";
            ExecStartPre = "+${lib.getExe render}";
            ExecStart = "${lib.getExe' pkgs.dex-oidc "dex"} serve ${runtimeDir}/config.json";
          }
        ];
      }
    ];
  };
}
