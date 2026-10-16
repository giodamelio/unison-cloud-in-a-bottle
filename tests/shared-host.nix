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

  # A second network in TEST-NET-3 stands in for the public internet; the test VLAN, a
  # private range, stands in for the LAN.
  public = {
    internet = "203.0.113.2";
    machine = "203.0.113.1";
  };
  # Only the internet node's resolver knows this name.
  internetName = "web.internet.test";

  s3Host = "s3.garage.example.com";
  buckets = {
    services = "carbon-unison-services";
    userBlobs = "carbon-unison-user-blobs";
  };
  s3KeyId = "GK0123456789abcdef01234567";
  s3Secret = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
  oidcClientSecret = "host-dex-client-secret";
  dbPasswords = {
    cloudApi = "host-cloud-api-db-password";
    nimbus = "host-nimbus-db-password";
  };
  consulTokens = {
    management = "6f1a7b3e-2c4d-4e5f-8a9b-0c1d2e3f4a5b";
    unisonCloud = "0d9c8b7a-6f5e-4d3c-9b2a-1f0e9d8c7b6a";
  };
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
    networking.firewall = {
      allowedTCPPorts = [53 80];
      allowedUDPPorts = [53];
    };
    systemd.services.http = {
      wantedBy = ["multi-user.target"];
      serviceConfig.ExecStart = "${lib.getExe pkgs.python3} -m http.server 80 --directory ${pkgs.writeTextDir "index.html" "hello from the internet\n"}";
    };
    services.dnsmasq = {
      enable = true;
      resolveLocalQueries = false;
      settings = {
        no-resolv = true;
        address = "/${internetName}/${public.internet}";
      };
    };
  };

  # A host that already runs its own Caddy, login provider, PostgreSQL, S3 store, Consul
  # and Loki, and resolves names with systemd-resolved. It imports core alone.
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
    imports = [self.nixosModules.core];

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
    networking.nameservers = [public.internet];
    services.resolved.enable = true;

    services.unison-cloud = {
      enable = true;
      nimbus.nodes.interactive = 1;
      domains = {
        api = "cloud.test";
        apps = "apps.test";
        ui = "ui.test";
      };

      auth.oidc = {
        issuer = "https://login.test";
        clientId = "unison-cloud";
        endpoints = {
          authorization = "https://login.test/auth";
          token = "http://127.0.0.1:5557/token";
          jwks = "http://127.0.0.1:5557/keys";
        };
        allowedEmails = ["alice@example.com"];
      };

      s3 = {
        inherit buckets;
        host = s3Host;
        port = 3900;
        https = false;
        region = "garage";
      };
      database.host = "127.0.0.1";
      logs.lokiUrl = "http://127.0.0.1:3100";

      secrets.credentials = {
        oidc-client-secret = "unison-cloud-oidc-client-secret";
        s3-access-key-id = "unison-cloud-s3-access-key-id";
        s3-secret-access-key = "unison-cloud-s3-secret-access-key";
        cloud-api-db-password = "unison-cloud-cloud-api-db-password";
        nimbus-db-password = "unison-cloud-nimbus-db-password";
        consul-token = "unison-cloud-consul-token";
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

    # The host's own Consul agent, a single server here, with every request denied unless
    # a token allows it. Its agent token is the management token, which only a test does.
    services.consul = {
      enable = true;
      extraConfig = {
        server = true;
        bootstrap_expect = 1;
        bind_addr = "127.0.0.1";
        client_addr = "127.0.0.1";
        acl = {
          enabled = true;
          default_policy = "deny";
          tokens = {
            initial_management = consulTokens.management;
            agent = consulTokens.management;
          };
        };
      };
    };

    # Creates the policy and token the way the README tells you to.
    systemd.services.consul-unison-cloud-token = {
      requires = ["consul.service"];
      after = ["consul.service"];
      requiredBy = ["unison-cloud-consul-services.service" "unison-cloud-api.service"];
      before = ["unison-cloud-consul-services.service" "unison-cloud-api.service"];
      path = [config.services.consul.package];
      environment.CONSUL_HTTP_TOKEN = consulTokens.management;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        until consul acl token read -self > /dev/null; do sleep 1; done
        consul acl policy create -name unison-cloud -rules @${cfg.consul.aclPolicy}
        consul acl token create -policy-name unison-cloud -secret ${consulTokens.unisonCloud}
      '';
    };

    services.loki = {
      enable = true;
      configuration = {
        auth_enabled = false;
        server = {
          http_listen_address = "127.0.0.1";
          http_listen_port = 3100;
          grpc_listen_address = "127.0.0.1";
          log_level = "warn";
        };
        common = {
          path_prefix = config.services.loki.dataDir;
          replication_factor = 1;
          instance_addr = "127.0.0.1";
          ring.kvstore.store = "inmemory";
          storage.filesystem = {
            chunks_directory = "${config.services.loki.dataDir}/chunks";
            rules_directory = "${config.services.loki.dataDir}/rules";
          };
        };
        schema_config.configs = [
          {
            from = "2024-01-01";
            store = "tsdb";
            object_store = "filesystem";
            schema = "v13";
            index = {
              prefix = "index_";
              period = "24h";
            };
          }
        ];
        limits_config.allow_structured_metadata = true;
        analytics.reporting_enabled = false;
      };
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
        encrypt cloud-api-db-password unison-cloud-cloud-api-db-password ${dbPasswords.cloudApi}
        encrypt nimbus-db-password unison-cloud-nimbus-db-password ${dbPasswords.nimbus}
        encrypt consul-token unison-cloud-consul-token ${consulTokens.unisonCloud}
      '';
    };

    # The host's PostgreSQL already serves another application. Its roles and databases
    # for the module are prepared by hand, as the module expects.
    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_18;
      initialScript = pkgs.writeText "init.sql" ''
        CREATE ROLE unrelated LOGIN;
        CREATE DATABASE unrelated OWNER unrelated;
        \c unrelated
        CREATE TABLE notes (body text);
        INSERT INTO notes VALUES ('untouched');
        ALTER TABLE notes OWNER TO unrelated;

        CREATE ROLE unison_cloud LOGIN PASSWORD '${dbPasswords.cloudApi}';
        CREATE DATABASE unison_cloud OWNER unison_cloud;
        REVOKE ALL ON DATABASE unison_cloud FROM PUBLIC;
        \c unison_cloud
        CREATE EXTENSION "uuid-ossp";
        CREATE EXTENSION citext;
        CREATE EXTENSION moddatetime;
        CREATE ROLE unison_cloud_nimbus LOGIN PASSWORD '${dbPasswords.nimbus}';
        CREATE DATABASE unison_cloud_nimbus OWNER unison_cloud_nimbus;
        REVOKE ALL ON DATABASE unison_cloud_nimbus FROM PUBLIC;
      '';
    };
    # The roles exist only once the initial script has run.
    systemd.services.unison-cloud-database = {
      requires = ["postgresql-setup.service"];
      after = ["postgresql-setup.service"];
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

    # Stands in for the listener ucm opens on a loopback port during `auth.login`, and for
    # a service on the host's loopback that hosted code reaches.
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
    interactive = next(n for n in nimbus_nodes if n["type"] == "interactive")
    interactive_unit = interactive["unit"]

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

    def consul(path, token="$(cat /etc/unison-cloud-consul-token)"):
        header = f"-H \"X-Consul-Token: {token}\"" if token else ""
        return f"curl -sf {header} 'http://127.0.0.1:8500{path}'"

    start_all()
    internet.wait_for_unit("http.service")
    internet.wait_for_unit("dnsmasq.service")
    machine.wait_for_unit("caddy.service")
    machine.wait_for_unit("dex.service")
    machine.wait_for_unit("garage-setup.service")
    machine.wait_for_unit("redirect-catcher.service")
    machine.wait_for_unit("unison-cloud-api.service")
    machine.wait_for_unit(interactive_unit, timeout=600)
    machine.wait_until_succeeds(f"test -f {ca}", timeout=60)
    machine.wait_until_succeeds(f"curl -sf --cacert {ca} -o /dev/null https://login.test/.well-known/openid-configuration", timeout=120)
    machine.wait_until_succeeds(f"curl -s --cacert {ca} -o /dev/null -w '%{{http_code}}' {api}/v2/account | grep -q 401", timeout=120)
    machine.succeed("printf %s ${consulTokens.unisonCloud} > /etc/unison-cloud-consul-token")

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

    # The client talks to both public domains through the host's Caddy. The Unison
    # runtime only reads the system bundle, so Caddy's local CA joins it privately.
    machine.succeed(f"cat /etc/ssl/certs/ca-certificates.crt {ca} > /root/ca-bundle.crt")

    def deploy(command):
        env = f"UNISON_CLOUD_HOST=cloud.test UNISON_CLOUD_HTTP_PORT=443 UNISON_CLOUD_USE_TLS=true UNISON_CLOUD_ACCESS_TOKEN={token}"
        output = machine.succeed(
            "unshare -m --propagation private sh -c "
            + shlex.quote(f"mount --bind /root/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt && env {env} deploy-program {command}")
        )
        name = command.split()[0]
        return dict(re.findall(r"(\w+)=(\S+)", next(l for l in output.splitlines() if l.startswith(name + " "))))

    with subtest("the host's Consul agent holds the registrations under the prefix, behind the token"):
        machine.wait_until_succeeds(
            consul("/v1/health/service/unison-cloud-nimbus-http?passing=true") + " | jq -e 'length == ${toString (builtins.length cfg.internal.nimbusNodes)}'",
            timeout=180,
        )
        machine.wait_until_succeeds(consul("/v1/health/service/unison-cloud-cloud-api?passing=true") + " | jq -e 'length == 1'", timeout=60)
        assert json.loads(machine.succeed(consul("/v1/catalog/services", token=""))) == {}

    with subtest("a deploy stores its code in Garage, and nimbus serves it from there"):
        url = deploy("hello")["url"]
        info = machine.succeed("garage bucket info ${buckets.services}")
        print(info)
        assert re.search(r"objects\W+[1-9]", info, re.IGNORECASE), info
        # A restarted node has nothing cached, so it fetches the code from Garage again.
        machine.systemctl(f"restart {interactive_unit}")
        machine.wait_for_unit(interactive_unit, timeout=300)
        machine.wait_until_succeeds(f"curl -sf --cacert {ca} {url} | grep -qx 'hello from deploy-program'", timeout=120)

    with subtest("hosted code's log lines reach cloud-api's log endpoint through the host's Loki"):
        machine.succeed(
            f"hurl --test --cacert {ca} --variable api={api} --variable host=cloud.test"
            f" --variable token={token} --variable 'line=deploy-program hello served' ${hurl "logs.hurl"}"
        )

    with subtest("cloud-api and nimbus resolve names through systemd-resolved inside their sandboxes"):
        machine.succeed("test -L /etc/resolv.conf")
        for unit in ["unison-cloud-api.service", interactive_unit]:
            out = machine.succeed(in_sandbox(unit, "${bin.getent} hosts ${internetName}"))
            assert out.startswith("${public.internet}"), (unit, out)

    with subtest("without a proxy, hosted code reaches the host's loopback, the LAN and the internet"):
        config = json.loads(machine.succeed(f"cat /run/unison-cloud-nimbus-{interactive['name']}/config.json"))
        assert "outboundProxy" not in config, config
        for target in [
            "http://127.0.0.1:8099/",
            "http://${nodes.internet.networking.primaryIPAddress}/",
            "http://${internetName}/",
        ]:
            service = deploy(f"fetch {target}")["url"]
            body = machine.succeed(f"curl -sf --cacert {ca} {service}")
            assert body == "status 200", (target, body)

    with subtest("nimbus can't reach the host's sockets or state"):
        machine.succeed("sudo -u nobody socat - UNIX-CONNECT:/run/unrelated/sock | grep -q unrelated-socket")
        machine.succeed("sudo -u nobody cat /var/lib/unrelated/data")
        machine.fail(in_sandbox(interactive_unit, "${bin.socat} - UNIX-CONNECT:/run/unrelated/sock"))
        machine.fail(in_sandbox(interactive_unit, "${bin.cat} /var/lib/unrelated/data"))
        machine.fail(in_sandbox(interactive_unit, "${bin.test} -e /run/postgresql/.s.PGSQL.5432"))
        machine.fail(in_sandbox(interactive_unit, "${bin.test} -e /run/dbus/system_bus_socket"))
        families = machine.succeed(f"systemctl show -P RestrictAddressFamilies {interactive_unit}")
        assert "AF_UNIX" not in families and "AF_INET" in families, families

    with subtest("cloud-api can't reach the host's sockets or state"):
        machine.fail(in_sandbox("unison-cloud-api.service", "${bin.socat} - UNIX-CONNECT:/run/unrelated/sock"))
        machine.fail(in_sandbox("unison-cloud-api.service", "${bin.cat} /var/lib/unrelated/data"))
        machine.fail(in_sandbox("unison-cloud-api.service", "${bin.test} -e /run/postgresql/.s.PGSQL.5432"))

    with subtest("the host's PostgreSQL 18 serves the module beside an unrelated database, which the module never touches"):
        assert psql("unrelated", "SELECT body FROM notes") == "untouched"
        assert psql("postgres", "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'unrelated'") == "unrelated"
        roles = psql("postgres", "SELECT rolname, rolsuper, rolcreaterole, rolcreatedb FROM pg_roles WHERE rolname LIKE 'unison%' ORDER BY rolname")
        assert roles == "unison_cloud|f|f|f\nunison_cloud_nimbus|f|f|f", roles
        owner = psql("unison_cloud_nimbus", "SELECT tableowner FROM pg_tables WHERE tablename = 'nimbus_kv'")
        assert owner == "unison_cloud_nimbus", owner
        assert machine.succeed("grep -c unison \"$(sudo -u postgres psql -XtA -c 'SHOW hba_file')\" || true").strip() == "0"

    with subtest("each role reaches only its own database, over TCP with its password"):
        machine.fail(in_sandbox(interactive_unit, "${bin.psql} -h /run/postgresql -d postgres -c 'SELECT 1'"))
        machine.fail(in_sandbox(interactive_unit, "${bin.psql} -h 127.0.0.1 -d unison_cloud_nimbus -U unison_cloud_nimbus -w -c 'SELECT 1'"))
        connect = "${bin.env} PGPASSWORD=${dbPasswords.nimbus} ${bin.psql} -h 127.0.0.1 -U unison_cloud_nimbus -XtA -v ON_ERROR_STOP=1"
        machine.succeed(in_sandbox(interactive_unit, f"{connect} -d unison_cloud_nimbus -c 'SELECT count(*) FROM nimbus_kv'"))
        machine.fail(in_sandbox(interactive_unit, f"{connect} -d unison_cloud -c 'SELECT count(*) FROM selfhost.environment_secrets'"))
        machine.fail("PGPASSWORD=${dbPasswords.cloudApi} psql -h 127.0.0.1 -U unison_cloud -d unison_cloud_nimbus -XtA -v ON_ERROR_STOP=1 -c 'SELECT count(*) FROM nimbus_kv'")

    with subtest("core runs none of the batteries and generates only its own secrets"):
        for unit in ["unison-cloud-postgresql", "unison-cloud-s3", "unison-cloud-loki", "unison-cloud-dex", "unison-cloud-outbound-proxy", "unison-cloud-consul"]:
            machine.fail(f"systemctl cat {unit}.service")
        generated = sorted(machine.succeed(f"ls {secrets}").split())
        assert generated == ["cloud-eddsa-key", "cloud-hmac-key", "cluster-token", "internal-auth-token", "share-eddsa-key"], generated

    with subtest("credential-supplied secrets are never written in plaintext"):
        machine.fail("grep -rqs ${s3Secret} /var/lib/unison-cloud /etc/credstore.encrypted")
  '';
}
