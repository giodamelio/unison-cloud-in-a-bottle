self: {
  name = "unison-cloud-api-boot";

  nodes.machine = {pkgs, ...}: {
    imports = [self.nixosModules.default];

    services.unison-cloud.enable = true;

    environment.systemPackages = [pkgs.awscli2 pkgs.redis];

    # nimbus only speaks virtual-host bucket addressing, so the S3 checks use it too.
    environment.etc."aws-config".text = ''
      [default]
      region = us-east-1
      s3 =
        addressing_style = virtual
    '';

    virtualisation.memorySize = 2048;
  };

  testScript = ''
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

    with subtest("nothing listens outside the namespace"):
        machine.fail("ss -Hltn | grep -E ':(7070|6379|8500|18443) '")
  '';
}
