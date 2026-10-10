self: {
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

  # A Postgres prepared the way the `database.external` documentation asks.
  nodes.db = {pkgs, ...}: {
    networking.firewall.allowedTCPPorts = [5432];
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

  nodes.external = {nodes, ...}: {
    imports = [self.nixosModules.default];

    networking.nftables.enable = true;

    services.unison-cloud = {
      enable = true;
      # This rung doesn't need nimbus, and its nodes would not fit in the VM's memory.
      nimbus.enable = false;
      domains = {
        api = "cloud.test";
        apps = "apps.test";
        ui = "ui.test";
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
          address = nodes.db.networking.primaryIPAddress;
          port = 5432;
        }
      ];
    };

    systemd.tmpfiles.rules = [
      "d /etc/unison-cloud-secrets 0700 root root"
      "f+ /etc/unison-cloud-secrets/cloud-api-db 0600 root root - cloud-api-password"
      "f+ /etc/unison-cloud-secrets/extenddb-db 0600 root root - extenddb-password"
    ];

    virtualisation.memorySize = 3072;
  };

  testScript = ''
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
        for s in ["cloud-api", "dex", "oauth2-proxy"]:
            machine.succeed(f"test -S /run/unison-cloud/{s}.sock")
        headers = "-H 'X-Auth-Request-User: sub-bob' -H 'X-Auth-Request-Preferred-Username: bob' -H 'X-Auth-Request-Email: bob@example.com'"
        machine.succeed(f"curl -sf {sock} {headers} http://x/selfhost/access-token")

    with subtest("an external Postgres over TCP with passwords"):
        db.wait_for_unit("postgresql.service")
        db.wait_for_open_port(5432)
        external.wait_for_unit("unison-cloud-api.service")
        external.wait_until_succeeds(f"curl -s {sock} -o /dev/null -w '%{{http_code}}' http://x/v2/account | grep -q 401", timeout=180)
        external.wait_for_unit("unison-cloud-extenddb-setup.service")
        assert int(db.succeed("sudo -u postgres psql -d unison_cloud -XtA -c 'SELECT count(*) FROM selfhost.applied_migrations'").strip()) > 0
        assert db.succeed("sudo -u postgres psql -XtA -c \"SELECT count(*) FROM pg_database WHERE datname LIKE 'extenddb%'\"").strip() == "2"
        external.fail("systemctl is-active unison-cloud-postgresql.service")
  '';
}
