{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  user = "unison-cloud-api";
  database = "unison_cloud";
  secrets = "${cfg.stateDir}/secrets";
  socketDir = cfg.internal.postgresSocketDir;
  psql = "${cfg.database.package}/bin/psql";

  # In production mode cloud-api files new environments under this cluster ID
  # (`defaultClusterId`), so the seeded cluster and nimbus's token must use it.
  clusterId = "d3ee426c-c252-4910-a861-08fccf85fb66";
  # The cluster row needs an owning user; this one never logs in.
  systemUserId = "7f3c2a1e-0d4b-4c6a-9e2f-5b8d1c3a7e90";

  migrate = pkgs.writeShellApplication {
    name = "unison-cloud-migrate";
    runtimeInputs = [cfg.database.package pkgs.coreutils pkgs.gnugrep];
    text = ''
      sql_dir=${cfg.cloudApi.package.sql}
      run_psql() {
        psql -h ${socketDir} -d ${database} -X -q -v ON_ERROR_STOP=1 "$@"
      }

      run_psql -c "CREATE SCHEMA IF NOT EXISTS selfhost" \
        -c "CREATE TABLE IF NOT EXISTS selfhost.applied_migrations (filename text PRIMARY KEY, sha256 text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())"

      # Upstream's filenames mix `-` and `_` after the date (2025_05_23_00 vs
      # 2025-08-18-01), and byte order would run a migration before the one that
      # creates its table. Treating `_` as `-` gives chronological order.
      mapfile -t files < <(
        for path in "$sql_dir"/*.sql; do
          file=$(basename "$path")
          [ "$file" = inserts.sql ] && continue
          printf '%s\t%s\n' "''${file//_/-}" "$file"
        done | LC_ALL=C sort | cut -f2
      )

      for file in "''${files[@]}"; do
        if ! [[ "$file" =~ ^[A-Za-z0-9._-]+$ ]]; then
          echo "unexpected migration filename: $file" >&2
          exit 1
        fi
        sha256=$(sha256sum "$sql_dir/$file" | cut -d' ' -f1)
        recorded=$(run_psql -tA -c "SELECT sha256 FROM selfhost.applied_migrations WHERE filename = '$file'")
        if [ "$recorded" = "$sha256" ]; then
          continue
        elif [ -n "$recorded" ]; then
          echo "migration $file was edited after it was applied (recorded $recorded, now $sha256)" >&2
          exit 1
        fi
        echo "applying $file"
        run_psql -1 -f "$sql_dir/$file" \
          -c "INSERT INTO selfhost.applied_migrations (filename, sha256) VALUES ('$file', '$sha256')"
      done
    '';
  };

  seedSql = pkgs.writeText "unison-cloud-seed.sql" ''
    INSERT INTO users (id, primary_email, email_verified, name, handle)
    VALUES ('${systemUserId}', 'system@${cfg.domains.api}', true, 'Unison Cloud', 'unison-cloud-system')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO cloud_clusters (id, name, hostname, service_uri_type, service_uri, cluster_uri, loki_uri, loki_task_name, user_id, created_by)
    VALUES (
      '${clusterId}', 'default', '${cfg.domains.api}', 'local',
      '${cfg.internal.publicUrl.apps}', '${cfg.internal.publicUrl.apps}',
      'http://127.0.0.1:3100', 'nimbus', '${systemUserId}', '${systemUserId}'
    )
    ON CONFLICT (id) DO UPDATE SET
      hostname = EXCLUDED.hostname,
      service_uri_type = EXCLUDED.service_uri_type,
      service_uri = EXCLUDED.service_uri,
      cluster_uri = EXCLUDED.cluster_uri,
      loki_uri = EXCLUDED.loki_uri,
      loki_task_name = EXCLUDED.loki_task_name;

    DELETE FROM cloud_cluster_tokens WHERE cluster_id = '${clusterId}';
    INSERT INTO cloud_cluster_tokens (cluster_id, created_by, token_hash)
    VALUES ('${clusterId}', '${systemUserId}', encode(sha512(convert_to(:'token', 'UTF8')), 'hex'));
  '';

  start = pkgs.writeShellScript "unison-cloud-api-start" ''
    creds=$CREDENTIALS_DIRECTORY
    export CLOUD_REDIS="redis://:$(< "$creds/redis-password")@127.0.0.1:${toString cfg.internal.redisPort}"
    export AWS_ACCESS_KEY_ID=$(< "$creds/s3-access-key-id")
    export AWS_SECRET_ACCESS_KEY=$(< "$creds/s3-secret-access-key")
    export CLOUD_EDDSA_KEY=$(< "$creds/cloud-eddsa-key")
    export SHARE_EDDSA_KEY=$(< "$creds/share-eddsa-key")
    export CLOUD_HMAC_KEY=$(< "$creds/cloud-hmac-key")
    export CLOUD_INTERNAL_AUTH_TOKEN=$(< "$creds/internal-auth-token")
    exec ${lib.getExe' cfg.cloudApi.package "cloud-exe"}
  '';
in {
  options.services.unison-cloud.internal = {
    cloudApiPort = lib.mkOption {
      type = lib.types.port;
      internal = true;
      readOnly = true;
      default = 5424;
      description = "cloud-api's HTTP port, on the namespace loopback.";
    };

    secretsPort = lib.mkOption {
      type = lib.types.port;
      internal = true;
      readOnly = true;
      default = 5426;
      description = "Port of cloud-api's Vault-compatible secrets listener, which nimbus uses.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${user} = {
      isSystemUser = true;
      group = user;
    };
    users.groups.${user} = {};

    services.unison-cloud.internal = {
      ingressSockets.cloud-api = cfg.internal.cloudApiPort;
      postgresRoles.${user} = {};
      # Untrusted extensions a database owner can't create; the migrations skip them once they exist.
      postgresDatabases.${database} = {
        owner = user;
        extensions = ["uuid-ossp" "citext" "moddatetime"];
      };
    };

    systemd.services.unison-cloud-migrate = lib.mkMerge [
      cfg.internal.inNamespace
      {
        description = "Apply Unison Cloud database migrations";
        requires = ["unison-cloud-postgresql-setup.service"];
        after = ["unison-cloud-postgresql-setup.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = user;
          Group = user;
          ExecStart = lib.getExe migrate;
        };
      }
    ];

    systemd.services.unison-cloud-seed = lib.mkMerge [
      cfg.internal.inNamespace
      {
        description = "Register the Unison Cloud cluster and its nimbus token";
        requires = ["unison-cloud-migrate.service" "unison-cloud-secrets.service"];
        after = ["unison-cloud-migrate.service" "unison-cloud-secrets.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = user;
          Group = user;
          LoadCredential = ["cluster-token:${secrets}/cluster-token"];
          ExecStart = pkgs.writeShellScript "unison-cloud-seed" ''
            ${psql} -h ${socketDir} -d ${database} -X -q -v ON_ERROR_STOP=1 -1 \
              -v token="$(< "$CREDENTIALS_DIRECTORY/cluster-token")" -f ${seedSql}
          '';
        };
      }
    ];

    systemd.services.unison-cloud-api = lib.mkMerge [
      cfg.internal.inNamespace
      {
        description = "Unison Cloud API";
        wantedBy = ["multi-user.target"];
        requires = [
          "unison-cloud-seed.service"
          "redis-unison-cloud.service"
          "unison-cloud-consul.service"
          "unison-cloud-s3.service"
        ];
        after = [
          "unison-cloud-seed.service"
          "redis-unison-cloud.service"
          "unison-cloud-consul.service"
          "unison-cloud-s3.service"
        ];
        environment = {
          CLOUD_DEPLOYMENT = "production";
          CLOUD_COMMIT = cfg.cloudApi.package.version;
          CLOUD_LOG_LEVEL = "INFO";

          CLOUD_API_ORIGIN = cfg.internal.publicUrl.api;
          # Share is never contacted, but the variable must parse as an origin.
          SHARE_API_ORIGIN = cfg.internal.publicUrl.api;
          CLOUD_CLOUD_UI_ORIGIN = cfg.internal.publicUrl.ui;
          CLOUD_CLOUD_HOMEPAGE_ORIGIN = cfg.internal.publicUrl.ui;
          CLOUD_API_SUFFIX = cfg.domains.api;

          NOMAD_ALLOC_PORT_cloud_http = toString cfg.internal.cloudApiPort;
          NOMAD_HOST_IP_cloud_tcp = "127.0.0.1";
          NOMAD_ALLOC_PORT_cloud_tcp = "5425";

          CLOUD_POSTGRES = "host=${socketDir} dbname=${database}";
          CLOUD_POSTGRES_CONN_MAX = "10";
          CONSUL_HOST = "http://127.0.0.1:${toString cfg.internal.consulPort}";

          CLOUD_ENVIRONMENTS_MOUNT = "environments";
          CLOUD_SECRETS_HOST = "127.0.0.1";
          CLOUD_SECRETS_PORT = toString cfg.internal.secretsPort;

          AWS_REGION = "us-east-1";
          CLOUD_S3_ENDPOINT = "http://127.0.0.1:${toString cfg.internal.s3Port}";
          CLOUD_S3_ADDRESSING = "path";
          CLOUD_CLOUD_SERVICE_BUCKET = "unison-cloud-services";

          CLOUD_SELFHOST_OIDC_ISSUER = cfg.internal.oidcIssuer;
          CLOUD_SELFHOST_DEFAULT_TIER = cfg.auth.defaultTier;

          # Hosted-business integrations a self-hosted user never reaches.
          CLOUD_SHARE_OAUTH_CLIENT_ID = "unused";
          CLOUD_SHARE_OAUTH_CLIENT_SECRET = "unused";
          CLOUD_STRIPE_API_SECRET_KEY = "rk_test_unused";
          CLOUD_STRIPE_WEBHOOK_SECRET_KEY = "whsec_unused";
          CLOUD_ZENDESK_API_USER = "unused";
          CLOUD_ZENDESK_API_TOKEN = "unused";
        };
        serviceConfig = {
          User = user;
          Group = user;
          LoadCredential = map (name: "${name}:${secrets}/${name}") [
            "redis-password"
            "s3-access-key-id"
            "s3-secret-access-key"
            "cloud-eddsa-key"
            "share-eddsa-key"
            "cloud-hmac-key"
            "internal-auth-token"
          ];
          ExecStart = start;
          Restart = "on-failure";
        };
      }
    ];
  };
}
