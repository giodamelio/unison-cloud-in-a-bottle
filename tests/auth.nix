self: {
  name = "unison-cloud-auth";

  nodes.machine = {
    config,
    pkgs,
    ...
  }: let
    # Built at evaluation time from a known test password; bcrypt's random salt doesn't matter here.
    hash = name: password: "${pkgs.runCommand "${name}.bcrypt" {} ''
      printf %s ${password} | ${pkgs.mkpasswd}/bin/mkpasswd -m bcrypt -R 10 -s > $out
    ''}";
  in {
    imports = [self.nixosModules.core self.nixosModules.batteries];

    services.unison-cloud = {
      enable = true;
      # This rung doesn't need nimbus, and its nodes would not fit in the VM's memory.
      nimbus.enable = false;
      domains = {
        api = "cloud.test";
        apps = "apps.test";
        ui = "ui.test";
      };
      # A non-default port proves every redirect carries it.
      ingress.port = 8443;
      batteries.dex.users = [
        {
          email = "alice@example.com";
          username = "alice";
          passwordHashFile = hash "alice" "alice-password";
        }
        {
          email = "mallory@example.com";
          username = "mallory";
          passwordHashFile = hash "mallory" "mallory-password";
        }
      ];
      auth.oidc.allowedEmails = ["alice@example.com" "admin@cloud.test"];
    };

    # The VMs have no network, so Caddy issues certificates from its own local CA.
    services.caddy.globalConfig = "local_certs";

    networking.hosts."127.0.0.1" = ["cloud.test" "ui.test" "apps.test"];

    environment.systemPackages = [pkgs.hurl config.services.unison-cloud.batteries.postgresql.package];

    # Stands in for the listener ucm opens on a loopback port during `auth.login`.
    systemd.services.redirect-catcher = {
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        DynamicUser = true;
        ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8099 --bind 127.0.0.1 --directory /var/empty";
      };
    };

    virtualisation.memorySize = 3072;
  };

  testScript = {nodes, ...}: let
    cfg = nodes.machine.services.unison-cloud;
    hurl = file: "${./hurl}/${file}";
  in ''
    import base64
    import hashlib
    import json
    import shlex

    secrets = "/var/lib/unison-cloud/secrets"
    api = "https://cloud.test:8443"
    ca = "/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt"

    def hurl(file, *args, cookies=None):
        jar = f" --cookie-jar {cookies}" if cookies else ""
        return machine.succeed(
            f"hurl --cacert {ca}{jar} --variable api={api} " + " ".join(args) + f" {file}"
        )

    verifier = "hurl-test-verifier-0123456789abcdefghijklmnopqrstuvwxyz"
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()

    def login_ucm(user, password, handle):
        response = hurl(
            "${hurl "login-ucm.hurl"}", f"--variable user={user}", f"--variable handle={handle}",
            "--variable redirect=http://127.0.0.1:8099/redirect", f"--variable verifier={verifier}",
            f"--variable challenge={challenge}", f"--secret password={password}",
        )
        return json.loads(response)

    def refresh(refresh_token):
        return (
            f"curl -s -o /dev/null -w '%{{http_code}}\\n' --cacert {ca} -d grant_type=refresh_token"
            f" -d refresh_token={refresh_token} {api}/selfhost/oidc/token"
        )

    def psql(query):
        return machine.succeed(
            "sudo -u unison-cloud-postgres psql -h /run/unison-cloud-postgresql -p ${toString cfg.database.port}"
            f" -d unison_cloud -XtA -v ON_ERROR_STOP=1 -c {shlex.quote(query)}"
        ).strip()

    machine.wait_for_unit("caddy.service")
    machine.wait_for_unit("unison-cloud-api.service")
    machine.wait_for_unit("redirect-catcher.service")
    machine.wait_for_unit("unison-cloud-dex.service")
    machine.wait_until_succeeds(f"test -f {ca}", timeout=60)
    machine.wait_until_succeeds(f"curl -sf --cacert {ca} -o /dev/null {api}/dex/.well-known/openid-configuration", timeout=120)
    machine.wait_until_succeeds(f"curl -s --cacert {ca} -o /dev/null -w '%{{http_code}}' {api}/v2/account | grep -q 401", timeout=120)

    with subtest("alice logs in the way ucm's auth.login does, through cloud-api and Dex"):
        token = login_ucm("alice@example.com", "alice-password", "alice")["access_token"]
        assert psql("SELECT u.handle FROM selfhost.oidc_identities i JOIN users u ON u.id = i.user_id WHERE i.issuer = 'https://cloud.test:8443/dex'") == "alice"
        assert psql("SELECT count(*) FROM cloud_users cu JOIN users u ON u.id = cu.user_id WHERE u.handle = 'alice'") == "1"

    # Dex accepts shorter verifiers, so the length is checked where cloud-api stores it.
    with subtest("cloud-api sends the provider a PKCE verifier of at least 43 characters, as RFC 7636 requires"):
        machine.succeed(f"curl -sf --cacert {ca} -o /dev/null {api}/selfhost/oidc/login")
        shortest = psql(
            # Values are JSON in Data.Binary's framing, which puts an 8-byte length first.
            "SELECT min(length(convert_from(substring(value FROM 9), 'UTF8')::jsonb->>'pkceVerifier')) FROM selfhost.ephemeral"
            " WHERE key LIKE 'sessions:pending:%'"
        )
        assert int(shortest) >= 43, f"shortest stored verifier has {shortest} characters"

    with subtest("the UI login sets a session cookie and returns to the UI"):
        hurl("${hurl "login-ui.hurl"}", "--test", "--variable ui=https://ui.test:8443", "--variable user=alice@example.com",
             "--variable handle=alice", "--secret password=alice-password")

    with subtest("a second login maps to the same user"):
        assert psql("SELECT count(*) FROM users WHERE handle = 'alice'") == "1"
        assert psql("SELECT count(*) FROM selfhost.oidc_identities") == "1"

    with subtest("a Dex user outside the allowlist is refused and never provisioned"):
        hurl("${hurl "login-denied.hurl"}", "--test", "--variable user=mallory@example.com", "--secret password=mallory-password")
        assert psql("SELECT count(*) FROM users WHERE handle = 'mallory'") == "0"

    with subtest("the API refuses everything that needs a login, and forged headers do nothing"):
        hurl("${hurl "auth-boundaries.hurl"}", "--test", f"--variable authorize={api}/dex/auth", f"--secret token={token}")

    with subtest("the generated admin user can log in"):
        password = machine.succeed(f"cat {secrets}/dex-admin-password").strip()
        login_ucm("admin@cloud.test", password, "admin")
        assert psql("SELECT count(*) FROM users WHERE handle = 'admin'") == "1"

    with subtest("of concurrent refreshes with one token, exactly one succeeds"):
        refresh_token = login_ucm("alice@example.com", "alice-password", "alice")["refresh_token"]
        codes = machine.succeed(" & ".join([refresh(refresh_token)] * 8) + " & wait").split()
        assert sorted(codes) == ["200"] + ["400"] * 7, codes

    with subtest("refresh tokens are stored only as hashes, refused once expired, and swept by the next write"):
        refresh_token = login_ucm("alice@example.com", "alice-password", "alice")["refresh_token"]
        assert int(psql("SELECT count(*) FROM selfhost.ephemeral WHERE key LIKE 'selfhost:oidc:refresh:%'")) > 0
        assert psql(f"SELECT count(*) FROM selfhost.ephemeral WHERE strpos(key, '{refresh_token}') > 0") == "0"
        psql("UPDATE selfhost.ephemeral SET expires_at = now() - interval '1 second'")
        assert machine.succeed(refresh(refresh_token)).strip() == "400"
        assert int(psql("SELECT count(*) FROM selfhost.ephemeral WHERE expires_at < now()")) > 0
        login_ucm("alice@example.com", "alice-password", "alice")
        assert psql("SELECT count(*) FROM selfhost.ephemeral WHERE expires_at < now()") == "0"
  '';
}
