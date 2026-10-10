{
  self,
  dynamoProbe,
}: {
  name = "unison-cloud-nimbus-dynamo";

  nodes.machine = {
    imports = [self.nixosModules.default];

    services.unison-cloud = {
      enable = true;
      domains = {
        api = "cloud.test";
        apps = "apps.test";
        ui = "ui.test";
      };
    };

    environment.systemPackages = [dynamoProbe];

    virtualisation.memorySize = 2048;
  };

  testScript = ''
    import json
    import shlex

    secrets = "/var/lib/unison-cloud/secrets"
    bundle = "/run/nimbus-ca-bundle.crt"

    machine.wait_for_unit("unison-cloud-extenddb-setup.service")

    config = json.dumps({
        "type": "local-https",
        "credentials": {
            "accessKey": machine.succeed(f"cat {secrets}/extenddb-access-key-id").strip(),
            "secretKey": machine.succeed(f"cat {secrets}/extenddb-secret-access-key").strip(),
        },
        "host": "extenddb.unison-cloud.internal",
        "port": "18443",
        "table": "unison-cloud",
    })
    machine.succeed(f"cat /etc/ssl/certs/ca-certificates.crt {secrets}/ca.crt > {bundle}")

    def probe(*properties):
        return (
            "systemd-run --wait --pipe --quiet"
            " -p NetworkNamespacePath=/run/netns/unison-cloud"
            + "".join(f" -p {p}" for p in properties)
            + f" --setenv=DYNAMO_CONFIG={shlex.quote(config)}"
            + " dynamo-probe"
        )

    with subtest("nimbus reaches ExtendDB over HTTPS once the CA bundle is bound over the system one"):
        status = machine.succeed(probe(f"BindReadOnlyPaths={bundle}:/etc/ssl/certs/ca-certificates.crt"))
        assert status.strip() == "ACTIVE", status

    with subtest("without the bundle the certificate is rejected, so TLS is verified"):
        error = machine.fail(probe() + " 2>&1")
        assert "UnknownCa" in error, error
  '';
}
