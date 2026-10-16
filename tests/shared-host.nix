{
  self,
  pkgs,
  deployProgram,
}: let
  # Commands run inside a unit's sandbox, where /run/current-system is hidden.
  bin = {
    cat = "${pkgs.coreutils}/bin/cat";
    env = "${pkgs.coreutils}/bin/env";
    test = "${pkgs.coreutils}/bin/test";
    getent = "${pkgs.getent}/bin/getent";
    socat = "${pkgs.socat}/bin/socat";
    psql = "${pkgs.postgresql_18}/bin/psql";
  };

  # A second network in TEST-NET-3 stands in for the public internet, as in namespace.nix.
  public = {
    internet = "203.0.113.2";
    machine = "203.0.113.1";
  };

  s3Host = "s3.garage.example.com";
  buckets = {
    services = "carbon-unison-services";
    userBlobs = "carbon-unison-user-blobs";
  };
  s3KeyId = "GK0123456789abcdef01234567";
  s3Secret = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
  oidcClientSecret = "host-dex-client-secret";
  # bcrypt of "demo", as in the demo VM.
  passwordHash = "$2b$10$/Lfz.yT3xdZwUBTJwkK29ObMuNl5lrS2rHlKJkJk054huJV4Vb9gm";
in {
  name = "unison-cloud-shared-host";

  nodes.internet = {
    lib,
    pkgs,
    ...
  }: {
    networking.interfaces.eth1.ipv4.addresses = [
      {
        address = public.internet;
        prefixLength = 24;
      }
    ];
    networking.firewall.allowedTCPPorts = [80];
    systemd.services.http = {
      wantedBy = ["multi-user.target"];
      serviceConfig.ExecStart = "${lib.getExe pkgs.python3} -m http.server 80 --directory ${pkgs.writeTextDir "index.html" "hello from the internet\n"}";
    };
  };

  # Modelled on a host that already runs its own Caddy, login provider, PostgreSQL and S3
  # store.
  nodes.machine = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.services.unison-cloud;
    vhost = name: body: {
      "https://${name}".extraConfig = ''
        tls internal
        ${body}
      '';
    };
  in {
    imports = [self.nixosModules.default];

    networking.interfaces.eth1.ipv4.addresses = [
      {
        address = public.machine;
        prefixLength = 24;
      }
    ];
    networking.hosts."127.0.0.1" = [
      "cloud.test"
      "apps.test"
      "ui.test"
      "login.test"
      s3Host
      "${buckets.services}.${s3Host}"
      "${buckets.userBlobs}.${s3Host}"
    ];

    services.unison-cloud = {
      enable = true;
      nimbus.nodes.interactive = 1;
      domains = {
        api = "cloud.test";
        apps = "apps.test";
        ui = "ui.test";
      };
      caddy.enable = false;

      auth = {
        dex.enable = false;
        oidc = {
          issuer = "https://login.test";
          clientId = "unison-cloud";
          clientSecretCredential = "unison-cloud-oidc-client-secret";
          endpoints = {
            authorization = "https://login.test/auth";
            token = "http://127.0.0.1:5557/token";
            jwks = "http://127.0.0.1:5557/keys";
          };
          allowedEmails = ["alice@example.com"];
        };
      };

      s3 = {
        bundled = false;
        inherit buckets;
        external = {
          host = s3Host;
          port = 3900;
          https = false;
          region = "garage";
        };
      };
      secrets.credentials = {
        s3-access-key-id = "unison-cloud-s3-access-key-id";
        s3-secret-access-key = "unison-cloud-s3-secret-access-key";
      };

      database = {
        mode = "host";
        package = config.services.postgresql.package;
      };
    };

    services.caddy = {
      enable = true;
      virtualHosts =
        vhost "cloud.test" cfg.caddy.siteConfig.api
        // vhost "apps.test" cfg.caddy.siteConfig.apps
        // vhost "ui.test" cfg.caddy.siteConfig.ui
        // vhost "login.test" "reverse_proxy 127.0.0.1:5557";
    };

    services.dex = {
      enable = true;
      settings = {
        issuer = "https://login.test";
        storage.type = "memory";
        web.http = "127.0.0.1:5557";
        enablePasswordDB = true;
        oauth2.skipApprovalScreen = true;
        staticPasswords = [
          {
            email = "alice@example.com";
            username = "alice";
            preferredUsername = "alice";
            hash = passwordHash;
            userID = "3e4f8a42-6f0e-4d1b-9a43-7c2a0f6d1b55";
          }
          {
            email = "mallory@example.com";
            username = "mallory";
            preferredUsername = "mallory";
            hash = passwordHash;
            userID = "9b1c2d3e-4f5a-4b6c-8d7e-0f1a2b3c4d5e";
          }
        ];
        staticClients = [
          {
            id = "unison-cloud";
            name = "Unison Cloud";
            secret = oidcClientSecret;
            redirectURIs = ["https://cloud.test/selfhost/oidc/callback"];
          }
        ];
      };
    };

    services.garage = {
      enable = true;
      package = pkgs.garage_2;
      settings = {
        replication_factor = 1;
        rpc_bind_addr = "127.0.0.1:3901";
        rpc_public_addr = "127.0.0.1:3901";
        rpc_secret = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";
        s3_api = {
          api_bind_addr = "127.0.0.1:3900";
          s3_region = "garage";
          root_domain = ".${s3Host}";
        };
      };
    };

    systemd.services.garage-setup = {
      wantedBy = ["multi-user.target"];
      requires = ["garage.service"];
      after = ["garage.service"];
      before = ["unison-cloud-api.service"];
      requiredBy = ["unison-cloud-api.service"];
      path = [config.services.garage.package pkgs.coreutils];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        until garage status; do sleep 1; done
        node=$(garage node id -q | cut -d@ -f1)
        garage layout assign -z dc1 -c 1G "$node"
        garage layout apply --version 1
        garage key import --yes -n unison-cloud ${s3KeyId} ${s3Secret}
        for bucket in ${buckets.services} ${buckets.userBlobs}; do
          garage bucket create "$bucket"
          garage bucket allow --read --write --owner "$bucket" --key unison-cloud
        done
      '';
    };

    # Stands in for credentials encrypted ahead of time; the plaintext only exists here.
    systemd.services.unison-cloud-test-credentials = {
      requiredBy = ["unison-cloud-secrets.service"];
      before = ["unison-cloud-secrets.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /etc/credstore.encrypted
        encrypt() {
          printf %s "$3" | ${config.systemd.package}/bin/systemd-creds encrypt --with-key=host --name="$1" - "/etc/credstore.encrypted/$2"
        }
        encrypt oidc-client-secret unison-cloud-oidc-client-secret ${oidcClientSecret}
        encrypt s3-access-key-id unison-cloud-s3-access-key-id ${s3KeyId}
        encrypt s3-secret-access-key unison-cloud-s3-secret-access-key ${s3Secret}
      '';
    };

    # The host's PostgreSQL already serves another application.
    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_18;
      initialScript = pkgs.writeText "unrelated.sql" ''
        CREATE ROLE unrelated LOGIN;
        CREATE DATABASE unrelated OWNER unrelated;
        \c unrelated
        CREATE TABLE notes (body text);
        INSERT INTO notes VALUES ('untouched');
        ALTER TABLE notes OWNER TO unrelated;
      '';
    };

    # An unrelated host service with a socket any user may connect to and a file any user
    # may read, which neither nimbus nor cloud-api should be able to reach.
    systemd.tmpfiles.rules = [
      "d /var/lib/unrelated 0755 root root"
      "f+ /var/lib/unrelated/data 0644 root root - unrelated-data"
    ];
    systemd.services.unrelated = {
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        RuntimeDirectory = "unrelated";
        RuntimeDirectoryMode = "0755";
        ExecStart = "${lib.getExe pkgs.socat} UNIX-LISTEN:/run/unrelated/sock,mode=0777,fork SYSTEM:'echo unrelated-socket'";
      };
    };

    # Stands in for the listener ucm opens on a loopback port during `auth.login`.
    systemd.services.redirect-catcher = {
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        DynamicUser = true;
        ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8099 --bind 127.0.0.1 --directory /var/empty";
      };
    };

    environment.systemPackages = [pkgs.hurl pkgs.socat pkgs.jq config.services.postgresql.package deployProgram];

    virtualisation.memorySize = 6144;
    virtualisation.cores = 4;
  };

  testScript = {nodes, ...}: let
    cfg = nodes.machine.services.unison-cloud;
    hurl = file: "${./hurl}/${file}";
  in ''
    import base64
    import hashlib
    import json
    import re
    import shlex

    secrets = "/var/lib/unison-cloud/secrets"
    api = "https://cloud.test"
    ca = "/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt"
    nimbus_nodes = json.loads(${builtins.toJSON (builtins.toJSON cfg.internal.nimbusNodes)})
    interactive = next(n["unit"] for n in nimbus_nodes if n["type"] == "interactive")

    def hurl(file, *args):
        return machine.succeed(f"hurl --cacert {ca} --variable api={api} " + " ".join(args) + f" {file}")

    def psql(database, query, user="postgres"):
        return machine.succeed(
            f"sudo -u {user} psql -h /run/postgresql -d {database} -XtA -v ON_ERROR_STOP=1 -c {shlex.quote(query)}"
        ).strip()

    def in_sandbox(unit, cmd):
        """Runs cmd as the unit's user, in its mount and network namespaces."""
        pid = machine.succeed(f"systemctl show -P MainPID {unit}").strip()
        user = machine.succeed(f"systemctl show -P User {unit}").strip()
        uid = machine.succeed(f"id -u {user}").strip()
        gid = machine.succeed(f"id -g {user}").strip()
        return f"nsenter -t {pid} -m -n -S {uid} -G {gid} -- {cmd}"

    start_all()
    internet.wait_for_unit("http.service")
    machine.wait_for_unit("caddy.service")
    machine.wait_for_unit("dex.service")
    machine.wait_for_unit("garage-setup.service")
    machine.wait_for_unit("redirect-catcher.service")
    machine.wait_for_unit("unison-cloud-api.service")
    machine.wait_for_unit(interactive, timeout=600)
    machine.wait_until_succeeds(f"test -f {ca}", timeout=60)
    machine.wait_until_succeeds(f"curl -sf --cacert {ca} -o /dev/null https://login.test/.well-known/openid-configuration", timeout=120)
    machine.wait_until_succeeds(f"curl -s --cacert {ca} -o /dev/null -w '%{{http_code}}' {api}/v2/account | grep -q 401", timeout=120)

    verifier = "hurl-test-verifier-0123456789abcdefghijklmnopqrstuvwxyz"
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()

    with subtest("a user logs in through the host's provider"):
        response = hurl(
            "${hurl "login-ucm.hurl"}", "--variable user=alice@example.com", "--variable handle=alice",
            "--variable redirect=http://127.0.0.1:8099/redirect", f"--variable verifier={verifier}",
            f"--variable challenge={challenge}", "--secret password=demo",
        )
        token = json.loads(response)["access_token"]
        # The identity is recorded against the public issuer, which the ID token's iss matched.
        issuer = psql("unison_cloud", "SELECT issuer FROM selfhost.oidc_identities i JOIN users u ON u.id = i.user_id WHERE u.handle = 'alice'")
        assert issuer == "https://login.test", issuer

    with subtest("a user outside the allowlist is refused"):
        hurl("${hurl "login-denied.hurl"}", "--test", "--variable user=mallory@example.com", "--secret password=demo")

    with subtest("the host's Caddy applies the exported site bodies"):
        hurl("${hurl "auth-boundaries.hurl"}", "--test", "--variable authorize=https://login.test/auth", f"--secret token={token}")

    with subtest("the health route answers without a login"):
        machine.succeed(f"curl -sf --cacert {ca} -o /dev/null {api}/.well-known/openid-configuration")

    with subtest("a deploy stores its code in Garage, and nimbus serves it from there"):
        machine.wait_until_succeeds(
            f"curl -sf -H \"X-Consul-Token: $(cat {secrets}/consul-token)\""
            " 'http://127.0.0.1:8500/v1/health/service/unison-cloud-nimbus-http?passing=true' | jq -e 'length == ${toString (builtins.length cfg.internal.nimbusNodes)}'",
            timeout=180,
        )
        # The client talks to both public domains through the host's Caddy. The Unison
        # runtime only reads the system bundle, so Caddy's local CA joins it privately.
        env = f"UNISON_CLOUD_HOST=cloud.test UNISON_CLOUD_HTTP_PORT=443 UNISON_CLOUD_USE_TLS=true UNISON_CLOUD_ACCESS_TOKEN={token}"
        machine.succeed(f"cat /etc/ssl/certs/ca-certificates.crt {ca} > /root/ca-bundle.crt")
        output = machine.succeed(
            "unshare -m --propagation private sh -c "
            + shlex.quote(f"mount --bind /root/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt && env {env} deploy-program hello")
        )
        url = dict(re.findall(r"(\w+)=(\S+)", next(l for l in output.splitlines() if l.startswith("hello "))))["url"]
        info = machine.succeed("garage bucket info ${buckets.services}")
        print(info)
        assert re.search(r"objects\W+[1-9]", info, re.IGNORECASE), info
        # A restarted node has nothing cached, so it fetches the code from Garage again.
        machine.systemctl(f"restart {interactive}")
        machine.wait_for_unit(interactive, timeout=300)
        machine.wait_until_succeeds(f"curl -sf --cacert {ca} {url} | grep -qx 'hello from deploy-program'", timeout=120)

    with subtest("nimbus can't reach the host's sockets or state"):
        machine.succeed("sudo -u nobody socat - UNIX-CONNECT:/run/unrelated/sock | grep -q unrelated-socket")
        machine.succeed("sudo -u nobody cat /var/lib/unrelated/data")
        machine.fail(in_sandbox(interactive, "${bin.socat} - UNIX-CONNECT:/run/unrelated/sock"))
        machine.fail(in_sandbox(interactive, "${bin.cat} /var/lib/unrelated/data"))
        machine.fail(in_sandbox(interactive, "${bin.test} -e /run/postgresql/.s.PGSQL.5432"))
        machine.fail(in_sandbox(interactive, "${bin.test} -e /run/dbus/system_bus_socket"))
        families = machine.succeed(f"systemctl show -P RestrictAddressFamilies {interactive}")
        assert "AF_UNIX" not in families and "AF_INET" in families, families

    with subtest("cloud-api can't reach the host's other sockets"):
        machine.fail(in_sandbox("unison-cloud-api.service", "${bin.socat} - UNIX-CONNECT:/run/unrelated/sock"))
        machine.fail(in_sandbox("unison-cloud-api.service", "${bin.cat} /var/lib/unrelated/data"))
        machine.succeed(in_sandbox("unison-cloud-api.service", "${bin.test} -S /run/postgresql/.s.PGSQL.5432"))

    with subtest("the host's PostgreSQL 18 serves the module beside an unrelated database"):
        assert psql("unrelated", "SELECT body FROM notes") == "untouched"
        assert psql("postgres", "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'unrelated'") == "unrelated"
        assert psql("postgres", "SELECT rolsuper OR rolcreaterole OR rolcreatedb FROM pg_roles WHERE rolname = 'unrelated'") == "f"
        roles = psql("postgres", "SELECT rolname, rolsuper, rolcreaterole, rolcreatedb FROM pg_roles WHERE rolname LIKE 'unison-cloud-%' ORDER BY rolname")
        assert roles == "unison-cloud-api|f|f|f\nunison-cloud-nimbus|f|f|f", roles
        dbs = psql("postgres", "SELECT datname FROM pg_database WHERE datname LIKE 'unison_cloud%' ORDER BY datname")
        assert dbs == "unison_cloud\nunison_cloud_nimbus", dbs
        owner = psql("unison_cloud_nimbus", "SELECT tableowner FROM pg_tables WHERE tablename = 'nimbus_kv'")
        assert owner == "unison-cloud-nimbus", owner
        extensions = psql("unison_cloud", "SELECT extname FROM pg_extension WHERE extname <> 'plpgsql' ORDER BY extname")
        assert extensions == "citext\nmoddatetime\nuuid-ossp", extensions
        assert machine.succeed("grep -c unison \"$(sudo -u postgres psql -XtA -c 'SHOW hba_file')\" || true").strip() == "0"

    with subtest("nimbus reaches the host's PostgreSQL over TCP, as its own role"):
        machine.fail(in_sandbox(interactive, "${bin.psql} -h /run/postgresql -d postgres -c 'SELECT 1'"))
        machine.fail(in_sandbox(interactive, "${bin.psql} -h 127.0.0.1 -d unison_cloud_nimbus -U unison-cloud-nimbus -w -c 'SELECT 1'"))
        password = machine.succeed(f"cat {secrets}/nimbus-db-password").strip()
        connect = f"${bin.env} PGPASSWORD={password} ${bin.psql} -h 127.0.0.1 -U unison-cloud-nimbus -XtA -v ON_ERROR_STOP=1"
        machine.succeed(in_sandbox(interactive, f"{connect} -d unison_cloud_nimbus -c 'SELECT count(*) FROM nimbus_kv'"))
        machine.fail(in_sandbox(interactive, f"{connect} -d unison_cloud -c 'SELECT count(*) FROM selfhost.environment_secrets'"))

    with subtest("cloud-api's role can't read nimbus's table"):
        machine.fail("sudo -u unison-cloud-api psql -h /run/postgresql -d unison_cloud_nimbus -XtA -v ON_ERROR_STOP=1 -c 'SELECT count(*) FROM nimbus_kv'")

    with subtest("with the bundled Dex off, none of it runs or exists"):
        machine.fail("systemctl cat unison-cloud-dex.service")
        for name in ["dex-client-secret", "dex-admin-password", "dex-admin-password.bcrypt"]:
            machine.fail(f"test -e {secrets}/{name}")

    with subtest("credential-supplied secrets are never written in plaintext"):
        for name in ["s3-access-key-id", "s3-secret-access-key", "oidc-client-secret"]:
            machine.fail(f"test -e {secrets}/{name}")
        machine.fail("grep -rqs ${s3Secret} /var/lib/unison-cloud /etc/credstore.encrypted")
  '';
}
