{
  self,
  storageProbe,
}: {
  name = "unison-cloud-nimbus-storage";

  nodes.machine = {
    config,
    pkgs,
    ...
  }: {
    imports = [self.nixosModules.default];

    services.unison-cloud = {
      enable = true;
      nimbus.nodes.interactive = 1;
      domains = {
        api = "cloud.test";
        apps = "apps.test";
        ui = "ui.test";
      };
    };

    environment.systemPackages = [storageProbe pkgs.jq config.services.unison-cloud.database.package];

    virtualisation.memorySize = 4096;
  };

  testScript = {nodes, ...}: let
    cfg = nodes.machine.services.unison-cloud;
  in ''
    import json
    import shlex

    secrets = "/var/lib/unison-cloud/secrets"
    socket = "/run/unison-cloud-postgresql"
    nimbus_nodes = json.loads(${builtins.toJSON (builtins.toJSON cfg.internal.nimbusNodes)})
    interactive = next(n for n in nimbus_nodes if n["type"] == "interactive")
    pg_port = ${toString cfg.database.port}

    def superuser(database, query):
        return f"sudo -u unison-cloud-postgres psql -h {socket} -p {pg_port} -d {database} -XtA -v ON_ERROR_STOP=1 -c {shlex.quote(query)}"

    def tcp(user, database, password, query):
        return (
            f"env PGPASSWORD={shlex.quote(password)} psql -h 127.0.0.1 -p {pg_port}"
            f" -U {user} -d {database} -XtA -v ON_ERROR_STOP=1 -c {shlex.quote(query)}"
        )

    machine.wait_for_unit(interactive["unit"], timeout=600)
    password = machine.succeed(f"cat {secrets}/nimbus-db-password").strip()
    api_password = machine.succeed(f"cat {secrets}/cloud-api-db-password").strip()

    with subtest("nimbus's node config points its storage at its own role, database and table"):
        config = json.loads(machine.succeed(f"jq -c .dynamo /run/unison-cloud-nimbus-{interactive['name']}/config.json"))
        assert config == {
            "type": "postgres",
            "host": "127.0.0.1",
            "port": pg_port,
            "user": "unison_cloud_nimbus",
            "database": "unison_cloud_nimbus",
            "table": "nimbus_kv",
            "password": password,
        }, config

    with subtest("nimbus's storage reads, writes and deletes, and a losing concurrent writer sees a conflict"):
        output = machine.succeed(
            "systemd-run --wait --pipe --quiet"
            " -p User=unison-cloud-nimbus"
            " -p RuntimeDirectory=unison-cloud-storage-probe --setenv=HOME=/run/unison-cloud-storage-probe"
            f" --setenv=STORAGE_CONFIG={shlex.quote(json.dumps(config))} storage-probe"
        )
        print(output)
        lines = [l.split("=", 1) for l in output.splitlines() if "=" in l]
        results = {k: v for k, v in lines if k != "race"}
        races = [v for k, v in lines if k == "race"]
        assert results["read"] == "42", results
        assert results["overwritten"] == "43", results
        assert results["deleted"] == "none", results
        assert results["batch"] == "1@1,none,2@1", results
        assert len(races) == 10, races
        for race in races:
            fields = dict(f.split("=") for f in race.split())
            assert fields["won"] == "1" and fields["conflicted"] == "1" and fields["errored"] == "0", race
            assert int(fields["version"]) == int(fields["from"]) + 1, race
        assert results["failedWorkers"] == "0", results
        assert results["counter"] == "40", results

    with subtest("the table belongs to nimbus's role and holds the probe's rows"):
        owner = machine.succeed(superuser("unison_cloud_nimbus", "SELECT tableowner FROM pg_tables WHERE tablename = 'nimbus_kv'")).strip()
        assert owner == "unison_cloud_nimbus", owner
        rows = int(machine.succeed(superuser("unison_cloud_nimbus", "SELECT count(*) FROM nimbus_kv WHERE ns LIKE '%:probe'")).strip())
        assert rows > 0, rows
        attrs = machine.succeed(superuser("postgres", "SELECT bool_or(rolsuper OR rolcreaterole OR rolcreatedb) FROM pg_roles WHERE rolname IN ('unison_cloud', 'unison_cloud_nimbus')")).strip()
        assert attrs == "f", attrs

    with subtest("each role logs in over TCP only to its own database, only with its password"):
        machine.succeed(tcp("unison_cloud_nimbus", "unison_cloud_nimbus", password, "SELECT count(*) FROM nimbus_kv"))
        machine.succeed(tcp("unison_cloud", "unison_cloud", api_password, "SELECT count(*) FROM selfhost.environment_secrets"))
        machine.fail(tcp("unison_cloud_nimbus", "unison_cloud_nimbus", "wrong", "SELECT 1"))
        machine.fail(tcp("unison_cloud_nimbus", "unison_cloud", password, "SELECT 1"))
        machine.fail(tcp("unison_cloud", "unison_cloud_nimbus", api_password, "SELECT 1"))
        machine.fail(tcp("unison-cloud-postgres", "postgres", "", "SELECT 1"))

    with subtest("PostgreSQL listens on loopback only"):
        listeners = machine.succeed(f"ss -Hltn | awk '{{print $4}}' | grep ':{pg_port}$'").split()
        assert listeners == [f"127.0.0.1:{pg_port}"], listeners

    with subtest("nothing of ExtendDB or the internal CA is left"):
        machine.fail("systemctl cat unison-cloud-extenddb.service")
        machine.fail("systemctl cat unison-cloud-nimbus-ca.service")
        for name in ["ca.crt", "ca.key", "extenddb.crt", "extenddb-access-key-id"]:
            machine.fail(f"test -e {secrets}/{name}")
  '';
}
