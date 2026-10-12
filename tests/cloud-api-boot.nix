self: {
  name = "unison-cloud-api-boot";

  nodes.machine = {
    config,
    pkgs,
    ...
  }: {
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
    };

    environment.systemPackages = [pkgs.awscli2 pkgs.redis pkgs.hurl config.services.unison-cloud.database.package];

    # nimbus only speaks virtual-host bucket addressing, so the S3 checks use it too.
    environment.etc."aws-config".text = ''
      [default]
      region = us-east-1
      s3 =
        addressing_style = virtual
    '';

    virtualisation.memorySize = 3072;
  };

  testScript = {nodes, ...}: let
    sql = nodes.machine.services.unison-cloud.cloudApi.package.sql;
  in ''
    import shlex

    secrets = "/var/lib/unison-cloud/secrets"

    def ns(cmd):
        return f"ip netns exec unison-cloud {cmd}"

    def s3(args):
        return ns(
            "env AWS_CONFIG_FILE=/etc/aws-config"
            f" AWS_ACCESS_KEY_ID=$(cat {secrets}/s3-access-key-id)"
            f" AWS_SECRET_ACCESS_KEY=$(cat {secrets}/s3-secret-access-key)"
            f" aws --endpoint-url http://s3.unison-cloud.internal:7070 s3api {args}"
        )

    machine.wait_for_unit("unison-cloud-s3.service")
    machine.wait_for_unit("redis-unison-cloud.service")
    machine.wait_for_unit("unison-cloud-consul.service")
    machine.wait_until_succeeds(ns("curl -s -o /dev/null http://127.0.0.1:7070/"), timeout=60)

    with subtest("both buckets exist"):
        buckets = machine.succeed(s3("list-buckets --query 'Buckets[].Name' --output text")).split()
        assert sorted(buckets) == ["unison-cloud-services", "unison-cloud-user-blobs"], buckets

    with subtest("a conditional create succeeds once, then fails with 412"):
        machine.succeed("echo hello > /tmp/object")
        machine.succeed(s3("put-object --bucket unison-cloud-services --key a/b --body /tmp/object --if-none-match '*'"))
        error = machine.fail(s3("put-object --bucket unison-cloud-services --key a/b --body /tmp/object --if-none-match '*'") + " 2>&1")
        assert "PreconditionFailed" in error or "412" in error, error

    with subtest("objects round-trip, including ranges"):
        machine.succeed(s3("get-object --bucket unison-cloud-services --key a/b /tmp/out"))
        machine.succeed("cmp /tmp/object /tmp/out")
        machine.succeed(s3("get-object --bucket unison-cloud-services --key a/b --range bytes=0-1 /tmp/range"))
        assert machine.succeed("cat /tmp/range") == "he"

    with subtest("S3 rejects wrong credentials"):
        machine.fail(ns(
            "env AWS_CONFIG_FILE=/etc/aws-config AWS_ACCESS_KEY_ID=AKIAWRONGWRONGWRONG0 AWS_SECRET_ACCESS_KEY=wrong"
            " aws --endpoint-url http://s3.unison-cloud.internal:7070 s3api list-buckets"
        ))

    with subtest("Redis requires its password"):
        assert "NOAUTH" in machine.succeed(ns("redis-cli -h 127.0.0.1 ping"))
        assert machine.succeed(ns(f"redis-cli -h 127.0.0.1 -a $(cat {secrets}/redis-password) --no-auth-warning ping")).strip() == "PONG"

    with subtest("Consul has elected itself leader"):
        machine.wait_until_succeeds(ns("curl -sf http://127.0.0.1:8500/v1/status/leader | grep -q 127.0.0.1"))

    def psql(query):
        return machine.succeed(ns(
            f"sudo -u unison-cloud-api psql -h /run/unison-cloud-postgresql -d unison_cloud -XtA -v ON_ERROR_STOP=1 -c {shlex.quote(query)}"
        )).strip()

    def api(args):
        return ns(f"curl -s -H 'Host: cloud.test' {args}")

    machine.wait_for_unit("unison-cloud-api.service")
    machine.wait_until_succeeds(api("-o /dev/null -w '%{http_code}' http://127.0.0.1:5424/v2/account | grep -q 401"), timeout=120)

    with subtest("every migration except the test seed data is applied and recorded"):
        applied = int(psql("SELECT count(*) FROM selfhost.applied_migrations"))
        files = int(machine.succeed("ls ${sql} | grep -v '^inserts.sql$' | grep -c '\\.sql$'"))
        assert applied == files, (applied, files)
        assert psql("SELECT count(*) FROM selfhost.applied_migrations WHERE filename = 'inserts.sql'") == "0"

    with subtest("a second run applies nothing"):
        machine.systemctl("restart unison-cloud-migrate.service")
        machine.wait_for_unit("unison-cloud-migrate.service")
        invocation = machine.succeed("systemctl show -P InvocationID unison-cloud-migrate.service").strip()
        machine.fail(f"journalctl _SYSTEMD_INVOCATION_ID={invocation} | grep -q applying")

    with subtest("an edited migration stops the migrate unit"):
        psql("UPDATE selfhost.applied_migrations SET sha256 = 'tampered' WHERE filename = '0000_initial.sql'")
        machine.fail(ns("systemctl restart unison-cloud-migrate.service"))
        assert "was edited after it was applied" in machine.succeed("journalctl -u unison-cloud-migrate.service")
        psql(f"UPDATE selfhost.applied_migrations SET sha256 = '{machine.succeed('sha256sum ${sql}/0000_initial.sql').split()[0]}' WHERE filename = '0000_initial.sql'")
        machine.systemctl("restart unison-cloud-migrate.service")
        machine.wait_for_unit("unison-cloud-migrate.service")
        # The failed migration took the seed and cloud-api down with it, through Requires=.
        machine.systemctl("start unison-cloud-api.service")
        machine.wait_until_succeeds(api("-o /dev/null -w '%{http_code}' http://127.0.0.1:5424/v2/account | grep -q 401"), timeout=120)

    with subtest("the seed registers the cluster and the hash of nimbus's token"):
        assert psql("SELECT hostname || ' ' || service_uri || ' ' || loki_uri FROM cloud_clusters WHERE id = 'd3ee426c-c252-4910-a861-08fccf85fb66'") == "cloud.test https://apps.test http://127.0.0.1:3100"
        token = machine.succeed(f"cat {secrets}/cluster-token").strip()
        expected = machine.succeed(f"printf %s {token} | sha512sum").split()[0]
        assert psql("SELECT token_hash FROM cloud_cluster_tokens") == expected

    with subtest("the secrets listener serves nimbus's requests, scoped to the token's cluster"):
        env = "11111111-1111-4111-8111-111111111111"
        other_env = "22222222-2222-4222-8222-222222222222"
        psql(
            "INSERT INTO cloud_clusters (id, name, hostname, service_uri_type, service_uri, cluster_uri, loki_uri, loki_task_name, user_id, created_by)"
            " SELECT '33333333-3333-4333-8333-333333333333', 'other', 'other.test', service_uri_type, service_uri, cluster_uri, loki_uri, loki_task_name, user_id, created_by"
            " FROM cloud_clusters WHERE id = 'd3ee426c-c252-4910-a861-08fccf85fb66'"
        )
        psql(
            "INSERT INTO cloud_environments (id, user_id, name, cluster_id) VALUES"
            f" ('{env}', '7f3c2a1e-0d4b-4c6a-9e2f-5b8d1c3a7e90', 'test', 'd3ee426c-c252-4910-a861-08fccf85fb66'),"
            f" ('{other_env}', '7f3c2a1e-0d4b-4c6a-9e2f-5b8d1c3a7e90', 'test', '33333333-3333-4333-8333-333333333333')"
        )
        machine.succeed(ns(
            f"hurl --test --variable base=http://127.0.0.1:5426 --variable env={env} --variable other_env={other_env}"
            f" --secret token=$(cat {secrets}/cluster-token) ${./hurl/secrets.hurl}"
        ))
        assert psql(f"SELECT count(*) FROM selfhost.environment_secrets WHERE environment_id = '{env}'") == "0"

    with subtest("on its loopback port, cloud-api has no way in but the OIDC login, forged headers or not"):
        machine.succeed(ns(
            "hurl --test --variable api=http://127.0.0.1:5424 --variable cluster=d3ee426c-c252-4910-a861-08fccf85fb66"
            f" --secret internal_token=$(cat {secrets}/internal-auth-token) ${./hurl/removed-routes.hurl}"
        ))
        assert psql("SELECT count(*) FROM users WHERE handle = 'forged'") == "0"

    with subtest("nothing listens outside the namespace"):
        machine.fail("ss -Hltn | grep -E ':(7070|6379|8500|18443|5424|5426) '")
  '';
}
