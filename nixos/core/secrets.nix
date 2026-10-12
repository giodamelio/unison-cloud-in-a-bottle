{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  dir = "${cfg.stateDir}/secrets";
  credentials = cfg.secrets.credentials;
  # systemd only decrypts a credential loaded under the name it was encrypted with, which
  # is the credstore name, or the file's basename when encrypted without --name.
  credentialId = name: let
    source = credentials.${name};
  in
    if lib.hasPrefix "/" source
    then baseNameOf source
    else source;
  loadingId = name:
    if credentials ? ${name}
    then credentialId name
    else name;
  loadingIds = map credentialId (lib.attrNames credentials);
  otherNames = lib.subtractLists (lib.attrNames credentials) (lib.unique (credentialNames ++ lib.attrNames cfg.internal.secretGenerators));
  clashingIds = lib.unique (lib.filter (id: lib.count (other: other == id) loadingIds > 1 || lib.elem id otherNames) loadingIds);
  credentialNames = [
    "cloud-eddsa-key"
    "share-eddsa-key"
    "cloud-hmac-key"
    "cluster-token"
    "internal-auth-token"
    "s3-access-key-id"
    "s3-secret-access-key"
    "cloud-api-db-password"
    "nimbus-db-password"
    "oidc-client-secret"
    "consul-token"
    "sentry-dsn"
  ];
  # Secrets core doesn't generate, so each needs a supplier: you, or a battery.
  requiredNames =
    ["s3-access-key-id" "s3-secret-access-key" "consul-token"]
    ++ lib.optionals cfg.cloudApi.enable ["cloud-api-db-password" "oidc-client-secret"]
    ++ lib.optional cfg.nimbus.enable "nimbus-db-password";
  supplied = name: cfg.secrets.files ? ${name} || credentials ? ${name};
  unsupplied = lib.filter (name: !(supplied name || cfg.internal.secretGenerators ? ${name})) requiredNames;

  gen = name: command: lib.optionalString (!(credentials ? ${name})) "generate ${name} ${command}";

  generate = pkgs.writeShellApplication {
    name = "unison-cloud-secrets";
    runtimeInputs = [pkgs.coreutils pkgs.openssl];
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

      # cloud-api reads its Ed25519 keys as the raw bytes of an environment variable and
      # needs exactly 32 of them, so they must be printable: 24 random bytes in base64.
      ${gen "cloud-eddsa-key" "openssl rand -base64 24"}
      ${gen "share-eddsa-key" "openssl rand -base64 24"}
      ${gen "cloud-hmac-key" "openssl rand -hex 32"}
      ${gen "cluster-token" "openssl rand -hex 32"}
      ${gen "internal-auth-token" "openssl rand -hex 32"}
      ${lib.concatStrings (lib.mapAttrsToList (name: command: ''
          ${gen name command}
        '')
        cfg.internal.secretGenerators)}
    '';
  };
in {
  options.services.unison-cloud.secrets.files = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    example = {
      cloud-eddsa-key = "/run/agenix/unison-cloud-signing-key";
      oidc-client-secret = "/run/secrets/oidc-client-secret";
    };
    description = ''
      Secrets to supply instead of generating, by name in `<stateDir>/secrets/`. Every
      start copies each file over the generated one; the rest are generated once and kept.
      The module generates `cloud-eddsa-key`, `share-eddsa-key` (32 printable bytes each),
      `cloud-hmac-key`, `cluster-token` and `internal-auth-token`. You supply
      `cloud-api-db-password`, `nimbus-db-password`, `s3-access-key-id`,
      `s3-secret-access-key`, `oidc-client-secret`, `consul-token` and, optionally,
      `sentry-dsn`, unless a battery generates them.
      Paths are strings so the secrets never enter the Nix store.
    '';
  };

  options.services.unison-cloud.secrets.credentials = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    example = {
      s3-access-key-id = "unison_cloud_s3_access_key_id";
      s3-secret-access-key = "/etc/credstore.encrypted/unison_cloud_s3_secret_access_key";
    };
    description = ''
      Secrets to supply as systemd encrypted credentials, by name, instead of generating
      them. Each value is a credential name in `/etc/credstore.encrypted/` or an absolute
      path, and every unit that needs the secret decrypts it with `LoadCredentialEncrypted`,
      so it is never written to disk in plaintext.

      systemd checks the name embedded in a credential against the name it's loaded as, and
      each one is loaded as its credential name, or its file's basename for a path. So
      encrypt each one under its own credstore name, or with no `--name` at all, for example
      `systemd-creds encrypt - /etc/credstore.encrypted/unison_cloud_s3_access_key_id`. No
      two can share a name, and none can take another secret's name.

      Names: ${lib.concatMapStringsSep ", " (name: "`${name}`") credentialNames}.
    '';
  };

  options.services.unison-cloud.internal.loadSecrets = lib.mkOption {
    type = lib.types.functionTo lib.types.attrs;
    internal = true;
    readOnly = true;
    default = names: {
      LoadCredential = map (name: "${name}:${dir}/${name}") (lib.filter (name: !(credentials ? ${name})) names);
      LoadCredentialEncrypted = map (name: "${credentialId name}:${credentials.${name}}") (lib.filter (name: credentials ? ${name}) names);
    };
    description = "Unit settings that load these secrets as credentials, from `secrets.credentials` or the secrets directory. Read each one at `secretPath`.";
  };

  options.services.unison-cloud.internal.secretPath = lib.mkOption {
    type = lib.types.functionTo lib.types.str;
    internal = true;
    readOnly = true;
    default = name: "$CREDENTIALS_DIRECTORY/${loadingId name}";
    description = "The path, for a shell, where a unit with `loadSecrets` reads this secret.";
  };

  options.services.unison-cloud.internal.secretGenerators = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    internal = true;
    default = {};
    example.oidc-client-secret = "openssl rand -hex 32";
    description = ''
      Shell commands that generate secrets the module otherwise needs you to supply, by
      name. Each runs once, in the secrets unit, unless the secret is supplied; a battery
      uses it for the secrets it creates itself.
    '';
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
      {
        assertion = clashingIds == [];
        message = "services.unison-cloud: secrets.credentials loads each secret under its credential name or file basename, and ${lib.concatStringsSep ", " clashingIds} is taken by more than one secret.";
      }
      {
        assertion = unsupplied == [];
        message = "services.unison-cloud: supply ${lib.concatStringsSep ", " unsupplied} through secrets.files or secrets.credentials.";
      }
    ];

    systemd.tmpfiles.settings.unison-cloud-state.${cfg.stateDir}.d = {
      user = "root";
      group = "root";
      mode = "0755";
    };

    systemd.services.unison-cloud-secrets = lib.mkMerge [
      cfg.internal.sandbox
      {
        description = "Generate Unison Cloud secrets";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # Supplied files may live under /root or /home.
          ProtectHome = "read-only";
          ProtectSystem = "strict";
          ReadWritePaths = [cfg.stateDir];
          PrivateNetwork = true;
          ExecStart = lib.getExe generate;
        };
      }
    ];
  };
}
