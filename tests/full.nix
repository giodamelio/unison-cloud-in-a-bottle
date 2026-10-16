{
  self,
  deployProgram,
}: {
  name = "unison-cloud-full";

  # The module as a user would write it: only the three domains, every default kept.
  nodes.machine = {pkgs, ...}: {
    imports = [self.nixosModules.core self.nixosModules.batteries];

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

    # Stands in for the listener ucm opens on a loopback port during `auth.login`.
    systemd.services.redirect-catcher = {
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        DynamicUser = true;
        ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8099 --bind 127.0.0.1 --directory /var/empty";
      };
    };

    virtualisation.memorySize = 7168;
    virtualisation.cores = 4;
  };

  testScript = {nodes, ...}: let
    cfg = nodes.machine.services.unison-cloud;
  in ''
    import base64
    import hashlib
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
        verifier = "hurl-test-verifier-0123456789abcdefghijklmnopqrstuvwxyz"
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        machine.wait_for_unit("redirect-catcher.service")
        token = json.loads(hurl(
            "${./hurl/login-ucm.hurl}", "--variable user=admin@cloud.test", "--variable handle=admin",
            "--variable redirect=http://127.0.0.1:8099/redirect", f"--variable verifier={verifier}",
            f"--variable challenge={challenge}", f"--secret password={password}",
        ))["access_token"]

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

    with subtest("the UI's deployment page gets the service's log line in a shape it can parse"):
        jar = "/tmp/ui-cookies"
        hurl("${./hurl/login-ui.hurl}", "--test", f"--cookie-jar {jar}", "--variable ui=https://ui.test",
             "--variable user=admin@cloud.test", "--variable handle=admin", f"--secret password={password}")
        end = machine.succeed("date -u +%Y-%m-%dT%H:%M:%S.%3NZ").strip()
        start = machine.succeed("date -u -d '48 hours ago' +%Y-%m-%dT%H:%M:%S.%3NZ").strip()
        response = json.loads(hurl(
            "${./hurl/logs-ui.hurl}", f"--cookie {jar}", "--variable ui=https://ui.test", f"--variable hash={hello['hash']}",
            f"--variable start={start}", f"--variable end={end}", "--variable 'line=deploy-program hello served'",
        ))
        # The UI drops, without a word, every entry JSON.parse rejects or that lacks id, time
        # and an object userMsg; nimbus's other user lines, such as UserServiceCall, lack them.
        messages = []
        for raw in response["logs"]:
            try:
                entry = json.loads(raw)
            except json.JSONDecodeError as e:
                raise AssertionError(f"the UI cannot parse log entry {raw!r}: {e}")
            if isinstance(entry.get("id"), str) and isinstance(entry.get("time"), str) and isinstance(entry.get("userMsg"), dict):
                messages.append(entry["userMsg"].get("message"))
        assert "deploy-program hello served" in messages, response

    with subtest("the UI is served and built for this API"):
        index = machine.succeed(f"curl -sf --cacert {ca} https://ui.test/")
        assert "<html" in index.lower()
        machine.succeed(f"curl -sf --cacert {ca} https://ui.test/some/client/route | grep -qi '<html'")
        machine.succeed("grep -rlq 'https://cloud.test/v2' ${cfg.ui.package}")
  '';
}
