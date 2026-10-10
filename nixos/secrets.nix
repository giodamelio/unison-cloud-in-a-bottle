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
    runtimeInputs = [pkgs.coreutils pkgs.openssl];
    text = ''
      umask 077
      mkdir -p ${dir}
      cd ${dir}

      generate() {
        local file=$1
        shift
        if [ ! -e "$file" ]; then
          "$@" > "$file.tmp"
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
