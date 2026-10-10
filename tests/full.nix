{
  self,
  deployProgram,
}: {
  name = "unison-cloud-full";

  # The module as a user would write it: only the three domains, every default kept.
  nodes.machine = {
    config,
    pkgs,
    ...
  }: {
    imports = [self.nixosModules.default];

    networking.nftables.enable = true;

    services.unison-cloud = {
      enable = true;
      domains = {
        api = "cloud.test";
        apps = "apps.test";
        ui = "ui.test";
      };
    };

    # The VMs have no network, so Caddy issues certificates from its own local CA.
    services.caddy.globalConfig = "local_certs";
    networking.hosts."127.0.0.1" = ["cloud.test" "apps.test" "ui.test"];

    environment.systemPackages = [deployProgram pkgs.hurl];

    virtualisation.memorySize = 7168;
    virtualisation.cores = 4;
  };

  testScript = {nodes, ...}: let
    cfg = nodes.machine.services.unison-cloud;
  in ''
    import json
    import re

    secrets = "/var/lib/unison-cloud/secrets"
    ca = "/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt"
    bundle = "/run/test-ca-bundle.crt"
    nodes = json.loads(${builtins.toJSON (builtins.toJSON cfg.internal.nimbusNodes)})

    def hurl(file, *args):
        return machine.succeed(f"hurl --cacert {ca} --variable api=https://cloud.test " + " ".join(args) + f" {file}")

    machine.wait_for_unit("multi-user.target")
    for node in nodes:
        machine.wait_for_unit(node["unit"])
    machine.wait_until_succeeds(f"test -f {ca}", timeout=60)
    machine.wait_until_succeeds(f"curl -s --cacert {ca} -o /dev/null -w '%{{http_code}}' https://cloud.test/v2/account | grep -q 401", timeout=180)

    with subtest("the default layout runs two interactive nodes and one public-daemon node"):
        assert sorted(n["type"] for n in nodes) == ["interactive", "interactive", "public-daemon"], nodes

    with subtest("the generated admin logs in through the bundled Dex"):
        password = machine.succeed(f"cat {secrets}/dex-admin-password").strip()
        token = hurl("${./hurl/login-token.hurl}", "--variable user=admin@cloud.test", f"--secret password={password}").strip()

    # The cloud client trusts the system bundle, so the deploy program runs with Caddy's CA added to it.
    machine.succeed(f"cat /etc/ssl/certs/ca-certificates.crt {ca} > {bundle}")

    def deploy(command):
        output = machine.succeed(
            "systemd-run --wait --pipe --quiet"
            f" -p BindReadOnlyPaths={bundle}:/etc/ssl/certs/ca-certificates.crt"
            f" --setenv=UNISON_CLOUD_HOST=cloud.test --setenv=UNISON_CLOUD_ACCESS_TOKEN={token}"
            f" ${deployProgram}/bin/deploy-program {command}"
        )
        line = next(l for l in output.splitlines() if l.startswith(command + " "))
        return dict(re.findall(r"(\w+)=(\S+)", line))

    with subtest("a deploy goes through Caddy to the apps domain, and the service answers there"):
        hello = deploy("hello")
        assert hello["url"].startswith("https://apps.test/"), hello
        machine.succeed(f"hurl --test --cacert {ca} --variable url={hello['url']} --variable 'expected=hello from deploy-program' ${./hurl/service.hurl}")

    with subtest("requests to the service are spread over both interactive nodes"):
        for _ in range(6):
            machine.succeed(f"curl -sf --cacert {ca} {hello['url']} -o /dev/null")
        interactive = [n["unit"] for n in nodes if n["type"] == "interactive"]
        for unit in interactive:
            machine.wait_until_succeeds(f"journalctl -u {unit} | grep -q 'deploy-program hello served'", timeout=60)

    with subtest("a daemon runs on the public-daemon node"):
        deploy("daemon")
        daemon_unit = next(n["unit"] for n in nodes if n["type"] == "public-daemon")
        machine.wait_until_succeeds(f"journalctl -u {daemon_unit} | grep -q 'deploy-program daemon tick'", timeout=120)

    with subtest("cloud-api's log search finds the service's log line through Loki"):
        machine.succeed(
            f"hurl --test --cacert {ca} --variable api=https://cloud.test --variable host=cloud.test"
            f" --variable token={token} --variable 'line=deploy-program hello served' ${./hurl/logs.hurl}"
        )

    with subtest("the UI is served and built for this API"):
        index = machine.succeed(f"curl -sf --cacert {ca} https://ui.test/")
        assert "<html" in index.lower()
        machine.succeed(f"curl -sf --cacert {ca} https://ui.test/some/client/route | grep -qi '<html'")
        machine.succeed("grep -rlq 'https://cloud.test/v2' ${cfg.ui.package}")
  '';
}
