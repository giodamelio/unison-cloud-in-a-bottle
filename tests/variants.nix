{
  self,
  deployProgram,
}: {
  name = "unison-cloud-variants";

  # One combination of levers: the host's Postgres over loopback TCP, secrets supplied as
  # files, and no bundled Caddy, so the upstream ports are the whole interface.
  nodes.machine = {pkgs, ...}: {
    imports = [self.nixosModules.core self.nixosModules.batteries];

    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_17;
      initialScript = pkgs.writeText "init.sql" ''
        CREATE ROLE unison_cloud LOGIN PASSWORD 'host-cloud-api-password';
        CREATE DATABASE unison_cloud OWNER unison_cloud;
        \c unison_cloud
        CREATE EXTENSION "uuid-ossp";
        CREATE EXTENSION citext;
        CREATE EXTENSION moddatetime;
      '';
    };
    # The role exists only once the initial script has run.
    systemd.services.unison-cloud-database = {
      requires = ["postgresql-setup.service"];
      after = ["postgresql-setup.service"];
    };

    services.unison-cloud = {
      enable = true;
      # This rung doesn't need nimbus, and its nodes would not fit in the VM's memory.
      nimbus.enable = false;
      domains = {
        api = "cloud.test";
        apps = "apps.test";
        ui = "ui.test";
      };
      database.host = "127.0.0.1";
      batteries = {
        postgresql.enable = false;
        caddy.enable = false;
      };
      secrets.files = {
        cluster-token = "/etc/unison-cloud-secrets/cluster-token";
        cloud-api-db-password = "/etc/unison-cloud-secrets/cloud-api-db";
      };
    };

    # Stands in for agenix or sops-nix: plain files outside the store, root-only.
    systemd.tmpfiles.rules = [
      "d /etc/unison-cloud-secrets 0700 root root"
      "f+ /etc/unison-cloud-secrets/cluster-token 0600 root root - supplied-cluster-token"
      "f+ /etc/unison-cloud-secrets/cloud-api-db 0600 root root - host-cloud-api-password"
    ];

    virtualisation.memorySize = 3072;
  };

  # A Postgres prepared the way `database` asks, and an S3 store with
  # virtual-host addressing, as `s3` needs.
  nodes.db = {
    lib,
    pkgs,
    ...
  }: {
    networking.firewall.allowedTCPPorts = [5432 7070];

    systemd.tmpfiles.rules = [
      "d /var/lib/s3/buckets/unison-cloud-services 0700 root root"
      "d /var/lib/s3/buckets/unison-cloud-user-blobs 0700 root root"
      "d /var/lib/s3/metadata 0700 root root"
    ];
    systemd.services.s3 = {
      wantedBy = ["multi-user.target"];
      environment = {
        ROOT_ACCESS_KEY = "AKIAEXTERNALS3TEST00";
        ROOT_SECRET_KEY = "external-s3-secret";
      };
      serviceConfig.ExecStart = "${lib.getExe pkgs.versitygw} --port :7070 --virtual-domain s3.test --quiet posix --sidecar /var/lib/s3/metadata /var/lib/s3/buckets";
    };

    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_17;
      enableTCPIP = true;
      authentication = "host all all 0.0.0.0/0 scram-sha-256";
      initialScript = pkgs.writeText "init.sql" ''
        CREATE ROLE unison_cloud LOGIN PASSWORD 'cloud-api-password';
        CREATE DATABASE unison_cloud OWNER unison_cloud;
        \c unison_cloud
        CREATE EXTENSION "uuid-ossp";
        CREATE EXTENSION citext;
        CREATE EXTENSION moddatetime;
        CREATE ROLE unison_cloud_nimbus LOGIN PASSWORD 'nimbus-password';
        CREATE DATABASE unison_cloud_nimbus OWNER unison_cloud_nimbus;
      '';
    };
  };

  nodes.external = {
    config,
    lib,
    nodes,
    pkgs,
    ...
  }: let
    interactive = lib.findFirst (node: node.type == "interactive") (throw "no interactive node") config.services.unison-cloud.internal.nimbusNodes;
    dbAddress = nodes.db.networking.primaryIPAddress;
  in {
    imports = [self.nixosModules.core self.nixosModules.batteries];

    networking.hosts = {
      "127.0.0.1" = ["cloud.localhost" "apps.localhost"];
      ${dbAddress} = ["s3.test" "unison-cloud-services.s3.test" "unison-cloud-user-blobs.s3.test"];
    };

    services.unison-cloud = {
      enable = true;
      nimbus.nodes.interactive = 1;
      # No reverse proxy here: the apps URL cloud-api hands the client points straight at
      # the interactive node's public port.
      domains = {
        api = "cloud.localhost";
        apps = "apps.localhost";
        ui = "ui.localhost";
      };
      ingress = {
        scheme = "http";
        port = interactive.ports.publicHttp;
      };
      batteries = {
        caddy.enable = false;
        postgresql.enable = false;
        s3.enable = false;
      };
      s3 = {
        host = "s3.test";
        port = 7070;
        https = false;
      };
      secrets.files = {
        s3-access-key-id = "/etc/unison-cloud-secrets/s3-access-key-id";
        s3-secret-access-key = "/etc/unison-cloud-secrets/s3-secret-access-key";
        cloud-api-db-password = "/etc/unison-cloud-secrets/cloud-api-db";
        nimbus-db-password = "/etc/unison-cloud-secrets/nimbus-db";
      };
      database.host = dbAddress;
    };

    systemd.tmpfiles.rules = [
      "d /etc/unison-cloud-secrets 0700 root root"
      "f+ /etc/unison-cloud-secrets/cloud-api-db 0600 root root - cloud-api-password"
      "f+ /etc/unison-cloud-secrets/nimbus-db 0600 root root - nimbus-password"
      "f+ /etc/unison-cloud-secrets/s3-access-key-id 0600 root root - AKIAEXTERNALS3TEST00"
      "f+ /etc/unison-cloud-secrets/s3-secret-access-key 0600 root root - external-s3-secret"
    ];

    environment.systemPackages = [deployProgram pkgs.hurl];

    virtualisation.memorySize = 4096;
    virtualisation.cores = 4;
  };

  testScript = {nodes, ...}: let
    inherit (nodes.machine.services.unison-cloud.ingress) upstreams;
    external = nodes.external.services.unison-cloud;
  in ''
    import base64
    import hashlib
    import json
    import re
    import shlex

    def psql(query):
        return machine.succeed(
            f"sudo -u postgres psql -d unison_cloud -XtA -v ON_ERROR_STOP=1 -c {shlex.quote(query)}"
        ).strip()

    upstream = "-H 'Host: cloud.test' http://${upstreams.api}"

    machine.wait_for_unit("unison-cloud-api.service")
    machine.wait_until_succeeds(f"curl -s -o /dev/null -w '%{{http_code}}' {upstream}/v2/account | grep -q 401", timeout=120)

    with subtest("the module's database lives in the host's Postgres, reached over loopback TCP"):
        assert machine.succeed("sudo -u postgres psql -XtA -c \"SELECT string_agg(datname, ',') FROM pg_database WHERE datname LIKE 'unison_cloud%'\"").strip() == "unison_cloud"
        assert int(psql("SELECT count(*) FROM selfhost.applied_migrations")) > 0
        machine.fail("systemctl is-active unison-cloud-postgresql.service")

    with subtest("supplied secrets are used verbatim"):
        expected = machine.succeed("printf %s supplied-cluster-token | sha512sum").split()[0]
        assert psql("SELECT token_hash FROM cloud_cluster_tokens") == expected

    with subtest("without the bundled Caddy, nothing listens publicly and the upstream ports are the interface"):
        machine.fail("systemctl is-active caddy.service")
        machine.fail("ss -Hltn | grep -E ':(80|443) '")
        machine.succeed(f"curl -sf -o /dev/null {upstream}/.well-known/openid-configuration")

    with subtest("an external Postgres over TCP with passwords"):
        db.wait_for_unit("postgresql.service")
        db.wait_for_open_port(5432)
        external.wait_for_unit("unison-cloud-api.service")
        external.wait_until_succeeds("curl -s -H 'Host: cloud.localhost' -o /dev/null -w '%{http_code}' http://${external.ingress.upstreams.api}/v2/account | grep -q 401", timeout=180)
        external.wait_for_unit("unison-cloud-nimbus-storage.service")
        assert int(db.succeed("sudo -u postgres psql -d unison_cloud -XtA -c 'SELECT count(*) FROM selfhost.applied_migrations'").strip()) > 0
        assert db.succeed("sudo -u postgres psql -d unison_cloud_nimbus -XtA -c \"SELECT tableowner FROM pg_tables WHERE tablename = 'nimbus_kv'\"").strip() == "unison_cloud_nimbus"
        external.fail("systemctl is-active unison-cloud-postgresql.service")

    with subtest("a deploy stores its code in the external S3"):
        db.wait_for_open_port(7070)
        external.fail("systemctl is-active unison-cloud-s3.service")
        for unit in external.succeed("systemctl list-units --plain --no-legend 'unison-cloud-nimbus-*-*.service' | cut -d' ' -f1").split():
            external.wait_for_unit(unit, timeout=600)
        external.wait_until_succeeds(
            "curl -sf -H \"X-Consul-Token: $(cat /var/lib/unison-cloud/secrets/consul-token)\""
            " 'http://127.0.0.1:8500/v1/health/service/unison-cloud-nimbus-http?passing=true' | grep -q nimbus",
            timeout=180,
        )
        verifier = "hurl-test-verifier-0123456789abcdefghijklmnopqrstuvwxyz"
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        external.wait_for_unit("unison-cloud-dex.service")
        token = json.loads(external.succeed(
            "hurl --connect-to ${external.domains.api}:${toString external.ingress.port}:127.0.0.1:${toString external.batteries.dex.port} --variable api=http://127.0.0.1:${toString external.cloudApi.port}"
            f" --variable user=admin@cloud.localhost --variable verifier={verifier} --variable challenge={challenge}"
            " --secret password=$(cat /var/lib/unison-cloud/secrets/dex-admin-password) ${./hurl/login-loopback.hurl}"
        ))["access_token"]
        env = f"UNISON_CLOUD_HOST=cloud.localhost UNISON_CLOUD_HTTP_PORT=${toString external.cloudApi.port} UNISON_CLOUD_USE_TLS=false UNISON_CLOUD_ACCESS_TOKEN={token}"
        output = external.succeed(f"env {env} deploy-program hello")
        url = dict(re.findall(r"(\w+)=(\S+)", next(l for l in output.splitlines() if l.startswith("hello "))))["url"]
        assert external.succeed(f"curl -sf {url}") == "hello from deploy-program"
        db.succeed("find /var/lib/s3/buckets/unison-cloud-services -type f | grep -q .")
  '';
}
