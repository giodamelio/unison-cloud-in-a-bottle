{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  dir = "${cfg.stateDir}/secrets";
  credentials = cfg.secrets.credentials;
  credentialNames = [
    "cloud-eddsa-key"
    "share-eddsa-key"
    "cloud-hmac-key"
    "cluster-token"
    "internal-auth-token"
    "redis-password"
    "s3-access-key-id"
    "s3-secret-access-key"
    "nimbus-db-password"
    "dex-client-secret"
  ];

  gen = name: command: lib.optionalString (!(credentials ? ${name})) "generate ${name} ${command}";

  generate = pkgs.writeShellApplication {
    name = "unison-cloud-secrets";
    runtimeInputs = [pkgs.coreutils pkgs.openssl pkgs.mkpasswd];
    text = ''
      umask 077
      mkdir -p ${dir}
      cd ${dir}

      ${lib.concatStrings (lib.mapAttrsToList (name: source: ''
          # Supplied secrets replace generated ones on every start, so rotating the file takes effect.
          tr -d '\n' < ${lib.escapeShellArg source} > ${name}.tmp
          mv ${name}.tmp ${name}
        '')
        cfg.secrets.files)}
      generate() {
        local file=$1
        shift
        if [ ! -e "$file" ]; then
          # No trailing newline: some consumers read the file verbatim.
          "$@" | tr -d '\n' > "$file.tmp"
          mv "$file.tmp" "$file"
        fi
      }

      # AWS-shaped, so SDKs accept it.
      access_key_id() {
        printf AKIA
        openssl rand -hex 8 | tr a-f A-F
      }

      ${gen "s3-access-key-id" "access_key_id"}
      ${gen "s3-secret-access-key" "openssl rand -hex 20"}
      ${gen "redis-password" "openssl rand -hex 24"}
      ${lib.optionalString (!cfg.internal.postgres.external) (gen "nimbus-db-password" "openssl rand -hex 24")}
      # cloud-api reads its Ed25519 keys as the raw bytes of an environment variable and
      # needs exactly 32 of them, so they must be printable: 24 random bytes in base64.
      ${gen "cloud-eddsa-key" "openssl rand -base64 24"}
      ${gen "share-eddsa-key" "openssl rand -base64 24"}
      ${gen "cloud-hmac-key" "openssl rand -hex 32"}
      ${gen "cluster-token" "openssl rand -hex 32"}
      ${gen "internal-auth-token" "openssl rand -hex 32"}
      ${lib.optionalString cfg.auth.dex.enable (gen "dex-client-secret" "openssl rand -hex 32")}
      ${lib.optionalString (cfg.auth.dex.enable && cfg.auth.dex.adminUser.enable) ''
        generate dex-admin-password openssl rand -hex 16
        if [ ! -e dex-admin-password.bcrypt ] || [ dex-admin-password -nt dex-admin-password.bcrypt ]; then
          mkpasswd -m bcrypt -R 10 -s < dex-admin-password | tr -d '\n' > dex-admin-password.bcrypt.tmp
          mv dex-admin-password.bcrypt.tmp dex-admin-password.bcrypt
        fi
      ''}
    '';
  };
in {
  options.services.unison-cloud.secrets.files = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    example = {
      cloud-eddsa-key = "/run/agenix/unison-cloud-signing-key";
      dex-client-secret = "/run/secrets/dex-client-secret";
    };
    description = ''
      Secrets to supply instead of generating, by name in `<stateDir>/secrets/`. Every
      start copies each file over the generated one; the rest are generated once and kept.
      Names: `cloud-eddsa-key`, `share-eddsa-key` (32 printable bytes each), `cloud-hmac-key`,
      `cluster-token`, `internal-auth-token`, `redis-password`, `s3-access-key-id`,
      `s3-secret-access-key`, `nimbus-db-password`, `dex-client-secret`,
      `dex-admin-password`.
      Paths are strings so the secrets never enter the Nix store.
    '';
  };

  options.services.unison-cloud.secrets.credentials = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    example = {
      s3-access-key-id = "unison-cloud-s3-access-key-id";
      s3-secret-access-key = "unison-cloud-s3-secret-access-key";
    };
    description = ''
      Secrets to supply as systemd encrypted credentials, by name, instead of generating
      them. Each value is a credential name in `/etc/credstore.encrypted/` or an absolute
      path, and every unit that needs the secret decrypts it with `LoadCredentialEncrypted`,
      so it is never written to disk in plaintext.

      systemd checks the name embedded in a credential against the name it's loaded as, so
      encrypt each one under the secret's name, for example
      `systemd-creds encrypt --name=s3-access-key-id - /etc/credstore.encrypted/unison-cloud-s3-access-key-id`.

      Names: ${lib.concatMapStringsSep ", " (name: "`${name}`") credentialNames}.
    '';
  };

  options.services.unison-cloud.internal.loadSecrets = lib.mkOption {
    type = lib.types.functionTo lib.types.attrs;
    internal = true;
    readOnly = true;
    default = names: {
      LoadCredential = map (name: "${name}:${dir}/${name}") (lib.filter (name: !(credentials ? ${name})) names);
      LoadCredentialEncrypted = map (name: "${name}:${credentials.${name}}") (lib.filter (name: credentials ? ${name}) names);
    };
    description = "Unit settings that load these secrets as credentials under their own names, from `secrets.credentials` or the secrets directory.";
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (name: lib.elem name credentialNames) (lib.attrNames credentials);
        message = "services.unison-cloud: secrets.credentials only takes ${lib.concatStringsSep ", " credentialNames}.";
      }
      {
        assertion = lib.all (name: !(cfg.secrets.files ? ${name})) (lib.attrNames credentials);
        message = "services.unison-cloud: supply each secret through secrets.files or secrets.credentials, not both.";
      }
    ];

    systemd.services.unison-cloud-secrets = {
      description = "Generate Unison Cloud secrets";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe generate;
      };
    };
  };
}
