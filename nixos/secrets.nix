{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  dir = "${cfg.stateDir}/secrets";

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
          # No trailing newline: some consumers (oauth2-proxy's secret files) read the file verbatim.
          "$@" | tr -d '\n' > "$file.tmp"
          mv "$file.tmp" "$file"
        fi
      }

      # AWS-shaped, so SDKs and ExtendDB's import validation accept it.
      access_key_id() {
        printf AKIA
        openssl rand -hex 8 | tr a-f A-F
      }

      generate extenddb-admin-password openssl rand -hex 24
      generate extenddb-access-key-id access_key_id
      generate extenddb-secret-access-key openssl rand -hex 20
      generate s3-access-key-id access_key_id
      generate s3-secret-access-key openssl rand -hex 20
      generate redis-password openssl rand -hex 24
      # cloud-api reads its Ed25519 keys as the raw bytes of an environment variable and
      # needs exactly 32 of them, so they must be printable: 24 random bytes in base64.
      generate cloud-eddsa-key openssl rand -base64 24
      generate share-eddsa-key openssl rand -base64 24
      generate cloud-hmac-key openssl rand -hex 32
      generate cluster-token openssl rand -hex 32
      generate internal-auth-token openssl rand -hex 32
      generate dex-client-secret openssl rand -hex 32
      # oauth2-proxy only accepts a cookie secret of 16, 24 or 32 bytes; 32 hex characters are 32 bytes.
      generate oauth2-proxy-cookie-secret openssl rand -hex 16
      generate dex-admin-password openssl rand -hex 16
      if [ ! -e dex-admin-password.bcrypt ] || [ dex-admin-password -nt dex-admin-password.bcrypt ]; then
        mkpasswd -m bcrypt -R 10 -s < dex-admin-password | tr -d '\n' > dex-admin-password.bcrypt.tmp
        mv dex-admin-password.bcrypt.tmp dex-admin-password.bcrypt
      fi

      if [ ! -e ca.crt ]; then
        openssl req -x509 -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
          -keyout ca.key -out ca.crt.tmp -days 36500 -subj "/CN=Unison Cloud internal CA" \
          -addext "basicConstraints=critical,CA:TRUE" \
          -addext "keyUsage=critical,keyCertSign,cRLSign"
        mv ca.crt.tmp ca.crt
      fi

      if [ ! -e extenddb.crt ]; then
        openssl req -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
          -keyout extenddb.key -out extenddb.csr -subj "/CN=extenddb"
        openssl x509 -req -in extenddb.csr -CA ca.crt -CAkey ca.key -out extenddb.crt.tmp -days 36500 \
          -extfile <(printf '%s\n' \
            "basicConstraints=critical,CA:FALSE" \
            "keyUsage=critical,digitalSignature" \
            "extendedKeyUsage=serverAuth" \
            "subjectKeyIdentifier=hash" \
            "authorityKeyIdentifier=keyid" \
            "subjectAltName=IP:127.0.0.1,DNS:localhost,DNS:${cfg.internal.extenddbHost}")
        rm extenddb.csr
        mv extenddb.crt.tmp extenddb.crt
      fi
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
      `s3-secret-access-key`, `extenddb-access-key-id`, `extenddb-secret-access-key`,
      `extenddb-admin-password`, `dex-client-secret`, `oauth2-proxy-cookie-secret`
      (16, 24 or 32 bytes), `dex-admin-password`.
      Paths are strings so the secrets never enter the Nix store.
    '';
  };

  config = lib.mkIf cfg.enable {
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
