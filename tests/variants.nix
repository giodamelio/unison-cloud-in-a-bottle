{
  self,
  deployProgram,
}: {
  name = "unison-cloud-variants";

  # One combination of levers: the host's Postgres, secrets supplied as files, and no
  # bundled Caddy, so the ingress sockets are the whole interface.
  nodes.machine = {
    config,
    pkgs,
    ...
  }: {
    imports = [self.nixosModules.default];

    networking.nftables.enable = true;

    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_17;
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
      database.mode = "host";
      caddy.enable = false;
      secrets.files = {
        cluster-token = "/etc/unison-cloud-secrets/cluster-token";
        redis-password = "/etc/unison-cloud-secrets/redis-password";
      };
    };

    # Stands in for agenix or sops-nix: plain files outside the store, root-only.
    systemd.tmpfiles.rules = [
      "d /etc/unison-cloud-secrets 0700 root root"
      "f+ /etc/unison-cloud-secrets/cluster-token 0600 root root - supplied-cluster-token"
      "f+ /etc/unison-cloud-secrets/redis-password 0600 root root - supplied-redis-password"
    ];

    environment.systemPackages = [pkgs.redis];

    virtualisation.memorySize = 3072;
  };

  # A Postgres prepared the way `database.external` asks, and an S3 store with
  # virtual-host addressing, as `s3.external` needs.
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
        CREATE ROLE extenddb LOGIN CREATEDB PASSWORD 'extenddb-password';
      '';
    };
  };

  nodes.external = {
    config,
    lib,
    nodes,
    ...
  }: let
    interactive = lib.findFirst (node: node.type == "interactive") (throw "no interactive node") config.services.unison-cloud.internal.nimbusNodes;
    dbAddress = nodes.db.networking.primaryIPAddress;
  in {
    imports = [self.nixosModules.default];

    networking.nftables.enable = true;
    networking.hosts = {
      ${dbAddress} = ["s3.test" "unison-cloud-services.s3.test" "unison-cloud-user-blobs.s3.test"];
      "127.0.0.1" = ["cloud.localhost" "apps.localhost"];
    };

    services.unison-cloud = {
      enable = true;
      nimbus.nodes.interactive = 1;
      # No reverse proxy here: the apps URL cloud-api hands the client points straight at
      # the interactive node's public port inside the namespace.
      domains = {
        api = "cloud.localhost";
        apps = "apps.localhost";
        ui = "ui.localhost";
      };
      ingress = {
        scheme = "http";
        port = interactive.ports.publicHttp;
      };
      caddy.enable = false;
      s3 = {
        bundled = false;
        external = {
          host = "s3.test";
          port = 7070;
          https = false;
        };
      };
      secrets.files = {
        s3-access-key-id = "/etc/unison-cloud-secrets/s3-access-key-id";
        s3-secret-access-key = "/etc/unison-cloud-secrets/s3-secret-access-key";
      };
      database = {
        mode = "external";
        external = {
          host = nodes.db.networking.primaryIPAddress;
          cloudApi.passwordFile = "/etc/unison-cloud-secrets/cloud-api-db";
          extenddb.passwordFile = "/etc/unison-cloud-secrets/extenddb-db";
        };
      };
      # The test network is a private range, which egress otherwise refuses.
      egress.allowedDestinations = [
        {
          address = dbAddress;
          port = 5432;
        }
        {
          address = dbAddress;
          port = 7070;
        }
      ];
    };

    systemd.tmpfiles.rules = [
      "d /etc/unison-cloud-secrets 0700 root root"
      "f+ /etc/unison-cloud-secrets/cloud-api-db 0600 root root - cloud-api-password"
      "f+ /etc/unison-cloud-secrets/extenddb-db 0600 root root - extenddb-password"
      "f+ /etc/unison-cloud-secrets/s3-access-key-id 0600 root root - AKIAEXTERNALS3TEST00"
      "f+ /etc/unison-cloud-secrets/s3-secret-access-key 0600 root root - external-s3-secret"
    ];

    environment.systemPackages = [deployProgram];

    virtualisation.memorySize = 4096;
    virtualisation.cores = 4;
  };

  testScript = ''
    import re
    import shlex

    def ns(cmd):
        return f"ip netns exec unison-cloud {cmd}"

    def psql(query):
        return machine.succeed(
            f"sudo -u unison-cloud-api psql -h /run/postgresql -d unison_cloud -XtA -v ON_ERROR_STOP=1 -c {shlex.quote(query)}"
        ).strip()

    sock = "--unix-socket /run/unison-cloud/cloud-api.sock -H 'Host: cloud.test'"

    machine.wait_for_unit("unison-cloud-api.service")
    machine.wait_until_succeeds(f"curl -s {sock} -o /dev/null -w '%{{http_code}}' http://x/v2/account | grep -q 401", timeout=120)

    with subtest("the module's databases live in the host's Postgres"):
        assert machine.succeed("sudo -u postgres psql -XtA -c \"SELECT count(*) FROM pg_database WHERE datname IN ('unison_cloud', 'extenddb', 'extenddb_catalog')\"").strip() == "3"
        assert int(psql("SELECT count(*) FROM selfhost.applied_migrations")) > 0
        machine.fail("systemctl is-active unison-cloud-postgresql.service")

    with subtest("ExtendDB initialised in the host's Postgres and created nimbus's table"):
        machine.wait_for_unit("unison-cloud-extenddb-setup.service")

    with subtest("supplied secrets are used verbatim"):
        expected = machine.succeed("printf %s supplied-cluster-token | sha512sum").split()[0]
        assert psql("SELECT token_hash FROM cloud_cluster_tokens") == expected
        assert machine.succeed(ns("redis-cli -h 127.0.0.1 -a supplied-redis-password --no-auth-warning ping")).strip() == "PONG"

    with subtest("without the bundled Caddy, nothing listens publicly and the sockets are the interface"):
        machine.fail("systemctl is-active caddy.service")
        machine.fail("ss -Hltn | grep -E ':(80|443) '")
        for s in ["cloud-api", "dex"]:
            machine.succeed(f"test -S /run/unison-cloud/{s}.sock")
        headers = "-H 'X-Auth-Request-User: sub-bob' -H 'X-Auth-Request-Preferred-Username: bob' -H 'X-Auth-Request-Email: bob@example.com'"
        machine.succeed(f"curl -sf {sock} {headers} http://x/selfhost/access-token")

    with subtest("an external Postgres over TCP with passwords"):
        db.wait_for_unit("postgresql.service")
        db.wait_for_open_port(5432)
        external.wait_for_unit("unison-cloud-api.service")
        external.wait_until_succeeds("curl -s --unix-socket /run/unison-cloud/cloud-api.sock -H 'Host: cloud.localhost' -o /dev/null -w '%{http_code}' http://x/v2/account | grep -q 401", timeout=180)
        external.wait_for_unit("unison-cloud-extenddb-setup.service")
        assert int(db.succeed("sudo -u postgres psql -d unison_cloud -XtA -c 'SELECT count(*) FROM selfhost.applied_migrations'").strip()) > 0
        assert db.succeed("sudo -u postgres psql -XtA -c \"SELECT count(*) FROM pg_database WHERE datname LIKE 'extenddb%'\"").strip() == "2"
        external.fail("systemctl is-active unison-cloud-postgresql.service")

    with subtest("a deploy stores its code in the external S3"):
        db.wait_for_open_port(7070)
        external.fail("systemctl is-active unison-cloud-s3.service")
        for unit in external.succeed("systemctl list-units --plain --no-legend 'unison-cloud-nimbus-*-*.service' | cut -d' ' -f1").split():
            external.wait_for_unit(unit, timeout=600)
        external.wait_until_succeeds(
            "ip netns exec unison-cloud curl -sf 'http://127.0.0.1:8500/v1/health/service/byoc-nimbus-http?passing=true' | grep -q nimbus",
            timeout=180,
        )
        headers = "-H 'Host: cloud.localhost' -H 'X-Auth-Request-User: sub-erin' -H 'X-Auth-Request-Preferred-Username: erin' -H 'X-Auth-Request-Email: erin@example.com'"
        token = external.succeed(f"ip netns exec unison-cloud curl -sf {headers} http://127.0.0.1:5424/selfhost/access-token").strip()
        env = f"UNISON_CLOUD_HOST=cloud.localhost UNISON_CLOUD_HTTP_PORT=5424 UNISON_CLOUD_USE_TLS=false UNISON_CLOUD_ACCESS_TOKEN={token}"
        output = external.succeed(f"ip netns exec unison-cloud env {env} deploy-program hello")
        url = dict(re.findall(r"(\w+)=(\S+)", next(l for l in output.splitlines() if l.startswith("hello "))))["url"]
        assert external.succeed(f"ip netns exec unison-cloud curl -sf {url}") == "hello from deploy-program"
        db.succeed("find /var/lib/s3/buckets/unison-cloud-services -type f | grep -q .")
  '';
}
