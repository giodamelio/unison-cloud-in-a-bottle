{
  self,
  deployProgram,
}: {
  name = "unison-cloud-demo";

  nodes.machine = {pkgs, ...}: {
    imports = [(import ../nix/demo/configuration.nix self)];

    environment.systemPackages = [deployProgram pkgs.hurl pkgs.jq];

    # Stands in for the listener ucm opens on a loopback port during `auth.login`.
    systemd.services.redirect-catcher = {
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        DynamicUser = true;
        ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8099 --bind 127.0.0.1 --directory /var/empty";
      };
    };

    virtualisation.memorySize = 6144;
    virtualisation.cores = 4;
  };

  testScript = {nodes, ...}: let
    cfg = nodes.machine.services.unison-cloud;
    url = cfg.internal.publicUrl;
    domains = cfg.domains;
    hurl = file: "${./hurl}/${file}";
  in ''
    import base64
    import hashlib
    import json
    import shlex

    api = "${url.api}"
    ui = "${url.ui}"

    def hurl(file, *args):
        return machine.succeed(f"hurl --variable api={api} " + " ".join(args) + f" {file}")

    verifier = "hurl-test-verifier-0123456789abcdefghijklmnopqrstuvwxyz"
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()

    def login_ucm(user, password, handle):
        response = hurl(
            "${hurl "login-ucm.hurl"}", f"--variable user={user}", f"--variable handle={handle}",
            "--variable redirect=http://127.0.0.1:8099/redirect", f"--variable verifier={verifier}",
            f"--variable challenge={challenge}", f"--secret password={password}",
        )
        return json.loads(response)["access_token"]

    machine.wait_for_unit("caddy.service")
    machine.wait_for_unit("unison-cloud-api.service")
    machine.wait_for_unit("redirect-catcher.service")
    machine.wait_for_unit("unison-cloud-dex.service")

    with subtest("every demo domain resolves to loopback through the system resolver"):
        for domain in ["${domains.api}", "${domains.apps}", "${domains.ui}"]:
            addresses = machine.succeed(f"getent ahostsv4 {domain} | cut -d' ' -f1 | sort -u").split()
            assert addresses == ["127.0.0.1"], (domain, addresses)

    with subtest("Caddy serves the UI and the API over plain HTTP"):
        machine.wait_until_succeeds(f"curl -sf -o /dev/null {ui}/", timeout=120)
        machine.wait_until_succeeds(f"curl -sf -o /dev/null {api}/dex/.well-known/openid-configuration", timeout=120)
        machine.wait_until_succeeds(f"curl -s -o /dev/null -w '%{{http_code}}' {api}/v2/account | grep -q 401", timeout=300)

    with subtest("the demo user logs in the way ucm's auth.login does, over plain HTTP"):
        token = login_ucm("demo@unison.localhost", "demo", "demo")

    with subtest("the UI login's session cookie works without TLS"):
        hurl("${hurl "login-ui.hurl"}", "--test", f"--variable ui={ui}", "--variable user=demo@unison.localhost",
             "--variable handle=demo", "--secret password=demo")

    with subtest("the generated admin user can log in"):
        password = machine.succeed("cat /var/lib/unison-cloud/secrets/dex-admin-password").strip()
        login_ucm("admin@${domains.api}", password, "admin")

    def deploy(command):
        env = (
            "UNISON_CLOUD_HOST=${domains.api} UNISON_CLOUD_HTTP_PORT=${toString cfg.ingress.port}"
            f" UNISON_CLOUD_USE_TLS=false UNISON_CLOUD_ACCESS_TOKEN={shlex.quote(token)}"
        )
        output = machine.succeed(f"env {env} deploy-program {command}")
        line = next(l for l in output.splitlines() if l.startswith(command + " "))
        return dict(field.split("=", 1) for field in line.split()[1:])

    units = ${builtins.toJSON (map (node: node.unit) cfg.internal.nimbusNodes)}
    for unit in units:
        machine.wait_for_unit(unit, timeout=600)
    # A deploy before cloud-api sees every node joined can land on no node at all.
    machine.wait_until_succeeds(
        "ip netns exec unison-cloud curl -sf 'http://127.0.0.1:8500/v1/health/service/byoc-nimbus-http?passing=true'"
        f" | jq -e 'length == {len(units)}'",
        timeout=300,
    )

    with subtest("a hello-world service deploys through the public URLs and answers"):
        hello = deploy("hello")
        assert hello["url"].startswith("${url.apps}/"), hello
        hurl("${hurl "service.hurl"}", "--test", f"--variable url={shlex.quote(hello['url'])}",
             "--variable 'expected=hello from deploy-program'")

    with subtest("the demo user's hello-world service is deployed on boot and answers"):
        machine.wait_for_unit("unison-cloud-demo-hello.service", timeout=900)
        url = machine.succeed("cat /var/lib/unison-cloud-demo/hello-url").strip()
        assert url.startswith("${url.apps}/services/"), url
        body = machine.succeed(f"curl -sf {shlex.quote(url)}")
        assert body.startswith("Hello, world!"), body
        # Named, so the URL is stable, and owned by the account the demo login reaches.
        assert "/services/s/demo/hello" in url, url
  '';
}
