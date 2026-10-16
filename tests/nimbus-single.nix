{
  self,
  deployProgram,
}: {
  name = "unison-cloud-nimbus-single";

  nodes.machine = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.services.unison-cloud;
    interactive = lib.findFirst (node: node.type == "interactive") (throw "no interactive node") cfg.internal.nimbusNodes;
  in {
    imports = [self.nixosModules.default];

    services.unison-cloud = {
      enable = true;
      domains = {
        api = "cloud.localhost";
        apps = "apps.localhost";
        ui = "ui.localhost";
      };
      nimbus.nodes.interactive = 1;
      # There's no reverse proxy in this test, so the apps URL cloud-api hands the client
      # points straight at the interactive node's public port.
      ingress = {
        scheme = "http";
        port = interactive.ports.publicHttp;
      };
      caddy.enable = false;
    };

    networking.hosts."127.0.0.1" = ["cloud.localhost" "apps.localhost"];

    environment.systemPackages = [deployProgram pkgs.hurl pkgs.jq cfg.database.package];

    virtualisation.memorySize = 4096;
    virtualisation.cores = 4;
  };

  testScript = {nodes, ...}: let
    cfg = nodes.machine.services.unison-cloud;
  in ''
    import base64
    import hashlib
    import json
    import re
    import shlex

    secrets = "/var/lib/unison-cloud/secrets"
    api_port = ${toString cfg.cloudApi.port}
    proxy = "http://127.0.0.1:${toString cfg.internal.outboundProxyPort}"
    nodes = json.loads(${builtins.toJSON (builtins.toJSON cfg.internal.nimbusNodes)})
    daemon_unit = next(n["unit"] for n in nodes if n["type"] == "public-daemon")
    interactive_units = [n["unit"] for n in nodes if n["type"] == "interactive"]

    def psql(database, query):
        return machine.succeed(
            f"sudo -u unison-cloud-postgres psql -h /run/unison-cloud-postgresql -p ${toString cfg.database.port} -d {database} -XtA -v ON_ERROR_STOP=1 -c {shlex.quote(query)}"
        ).strip()

    def hurl(file, **variables):
        args = " ".join(f"--variable {k}={shlex.quote(v)}" for k, v in variables.items())
        machine.succeed(f"hurl --test --very-verbose {args} {file}")

    def memory():
        for n in nodes:
            used = int(machine.succeed(f"systemctl show -P MemoryCurrent {n['unit']}"))
            print(f"memory {n['unit']}: {used // (1024 * 1024)} MiB")

    machine.wait_for_unit("unison-cloud-api.service")
    for n in nodes:
        machine.wait_for_unit(n["unit"], timeout=600)
    memory()

    def consul(path, anonymous=False):
        token = "" if anonymous else f"-H \"X-Consul-Token: $(cat {secrets}/consul-token)\""
        return f"curl -sf {token} 'http://127.0.0.1:8500{path}'"

    with subtest("cloud-api registers every node in Consul and its health checks pass"):
        machine.wait_until_succeeds(
            consul("/v1/health/service/unison-cloud-nimbus-http?passing=true") + f" | jq -e 'length == {len(nodes)}'",
            timeout=120,
        )
        machine.wait_until_succeeds(
            consul("/v1/health/service/unison-cloud-nimbus-client?passing=true") + f" | jq -e 'length == {len(nodes)}'",
            timeout=60,
        )
        machine.wait_until_succeeds(
            consul("/v1/health/service/unison-cloud-cloud-api?passing=true") + " | jq -e 'length == 1'",
            timeout=60,
        )

    verifier = "hurl-test-verifier-0123456789abcdefghijklmnopqrstuvwxyz"
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    machine.wait_for_unit("unison-cloud-dex.service")
    token = json.loads(machine.succeed(
        f"hurl --connect-to ${cfg.domains.api}:${toString cfg.ingress.port}:127.0.0.1:${toString cfg.internal.dexPort} --variable api=http://127.0.0.1:{api_port}"
        f" --variable user=admin@cloud.localhost --variable verifier={verifier} --variable challenge={challenge}"
        f" --secret password=$(cat {secrets}/dex-admin-password) ${./hurl/login-loopback.hurl}"
    ))["access_token"]

    def deploy(command):
        env = f"UNISON_CLOUD_HOST=cloud.localhost UNISON_CLOUD_HTTP_PORT={api_port} UNISON_CLOUD_USE_TLS=false UNISON_CLOUD_ACCESS_TOKEN={token}"
        output = machine.succeed(f"env {env} deploy-program {command}")
        line = next(l for l in output.splitlines() if l.startswith(command + " "))
        return dict(re.findall(r"(\w+)=(\S+)", line))

    with subtest("a hello-world service deploys and answers"):
        hello = deploy("hello")
        hurl("${./hurl/service.hurl}", url=hello["url"], expected="hello from deploy-program")

    with subtest("transactional storage goes through nimbus's PostgreSQL table"):
        deploy("storage")
        rows = psql("unison_cloud_nimbus", "SELECT count(*) FROM nimbus_kv WHERE ns LIKE '%:deploy-program'")
        assert int(rows) >= 1, rows

    with subtest("environment variables go through cloud-api's secrets listener"):
        env_set = deploy("env-set")
        hurl("${./hurl/service.hurl}", url=env_set["url"], expected="hello from the environment")
        stored = psql("unison_cloud", f"SELECT data->>'DEPLOY_PROGRAM_GREETING' FROM selfhost.environment_secrets WHERE environment_id = '{env_set['env']}'")
        assert stored == "hello from the environment", stored

    with subtest("deleting the environment deletes its secrets"):
        env_delete = deploy("env-delete")
        assert env_delete["env"] == env_set["env"], (env_delete, env_set)
        assert psql("unison_cloud", f"SELECT count(*) FROM selfhost.environment_secrets WHERE environment_id = '{env_set['env']}'") == "0"

    with subtest("a daemon runs on the public-daemon node"):
        deploy("daemon")
        machine.wait_until_succeeds(f"journalctl -u {daemon_unit} | grep -q 'deploy-program daemon tick'", timeout=120)
        for unit in interactive_units:
            machine.fail(f"journalctl -u {unit} | grep -q 'deploy-program daemon tick'")

    with subtest("cloud-api keeps its Consul keys and services under the prefix, out of anonymous reach"):
        keys = json.loads(machine.succeed(consul("/v1/kv/?keys")))
        assert keys and all(k.startswith("unison-cloud/daemons/") for k in keys), keys
        services = json.loads(machine.succeed(consul("/v1/catalog/services")))
        assert sorted(services) == ["unison-cloud-cloud-api", "unison-cloud-nimbus-client", "unison-cloud-nimbus-http"], services
        machine.fail(consul("/v1/kv/unison-cloud/?keys", anonymous=True))
        assert json.loads(machine.succeed(consul("/v1/catalog/services", anonymous=True))) == {}
        assert json.loads(machine.succeed(consul("/v1/health/service/unison-cloud-nimbus-http", anonymous=True))) == []

    with subtest("hosted code's log lines reach cloud-api's log endpoint through Loki"):
        hurl("${./hurl/logs.hurl}", api=f"http://127.0.0.1:{api_port}", host="cloud.localhost", token=token, line="deploy-program hello served")

    with subtest("the outbound proxy refuses loopback and private destinations"):
        def through_proxy(url, *extra):
            return machine.succeed(
                f"curl -s -o /dev/null -w '%{{http_code}}' -x {proxy} {' '.join(extra)} {url}"
            )
        assert through_proxy("http://127.0.0.1:8500/v1/status/leader") == "403"
        assert through_proxy("http://10.0.2.2/") == "403"
        assert through_proxy("http://169.254.169.254/latest/meta-data/") == "403"
        # The host's /etc/hosts names don't resolve through the proxy at all.
        assert through_proxy("http://localhost:5432/") in ("403", "503"), "localhost"
        machine.fail(f"curl -sf -x {proxy} -p https://127.0.0.1:5432/")

    memory()

    with subtest("a node stops gracefully through its shutdown endpoint"):
        unit = interactive_units[0]
        machine.systemctl(f"stop {unit}")
        assert machine.succeed(f"systemctl show -P Result {unit}").strip() == "success"
        machine.fail(f"journalctl -u {unit} | grep -q 'State .stop-sigterm. timed out'")
  '';
}
