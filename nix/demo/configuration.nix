self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  url = cfg.internal.publicUrl;
  system = pkgs.stdenv.hostPlatform.system;

  demoHello = pkgs.callPackage ./hello {
    inherit (self.inputs.unison-nix.packagesLib.${system}) buildFromTranscript;
  };

  # Logs in as the demo user the way ucm's auth.login does, so the service belongs to
  # the same account the browser login reaches, then deploys and records the URL.
  deployHello = pkgs.writeShellApplication {
    name = "unison-cloud-demo-hello";
    runtimeInputs = [pkgs.coreutils pkgs.gnugrep pkgs.hurl pkgs.jq pkgs.openssl pkgs.python3 demoHello];
    text = ''
      out=/var/lib/unison-cloud-demo/hello-url
      if [[ -s $out ]]; then
        exit 0
      fi

      cd "$(mktemp -d)"
      python3 -m http.server 8098 --bind 127.0.0.1 --directory /var/empty >/dev/null 2>&1 &
      catcher=$!
      trap 'kill $catcher' EXIT

      verifier=demo-hello-verifier-0123456789abcdefghijklmnopqrstuvwxyz
      challenge=$(printf %s "$verifier" | openssl dgst -sha256 -binary | basenc --base64url | tr -d '=')

      # The stack comes up in stages, so keep trying until a deploy lands on a node.
      for attempt in $(seq 1 60); do
        if token=$(hurl --variable api=${url.api} --variable user=demo@unison.localhost --variable handle=demo \
              --variable redirect=http://127.0.0.1:8098/redirect --variable verifier="$verifier" \
              --variable challenge="$challenge" --secret password=demo \
              ${../../tests/hurl/login-ucm.hurl} | jq -r .access_token) \
            && output=$(UNISON_CLOUD_HOST=${cfg.domains.api} UNISON_CLOUD_HTTP_PORT=${toString cfg.ingress.port} \
              UNISON_CLOUD_USE_TLS=false UNISON_CLOUD_ACCESS_TOKEN="$token" demo-hello); then
          hello=$(grep -o '^url=.*' <<< "$output" | cut -d= -f2-)
          mkdir -p "$(dirname "$out")"
          printf '%s\n' "$hello" > "$out"
          echo "deployed the demo's hello service at $hello"
          exit 0
        fi
        echo "attempt $attempt: the stack isn't ready to take a deploy yet"
        sleep 10
      done
      echo "gave up deploying the demo's hello service" >&2
      exit 1
    '';
  };
in {
  imports = [self.nixosModules.core self.nixosModules.batteries];

  services.unison-cloud = {
    enable = true;
    # One parent domain on purpose: the session cookie is SameSite=Lax without a Domain,
    # so the UI's requests only carry it when the UI and API are the same site.
    domains = {
      api = "cloud.unison.localhost";
      apps = "apps.unison.localhost";
      ui = "ui.unison.localhost";
    };
    ingress = {
      scheme = "http";
      port = 8080;
    };
    batteries.dex.users = [
      {
        email = "demo@unison.localhost";
        username = "demo";
        # A literal rather than a hash built at evaluation time: bcrypt salts randomly, so
        # a built hash would change the VM's store paths on every build.
        passwordHashFile = "${pkgs.writeText "unison-cloud-demo-password.bcrypt" "$2b$10$/Lfz.yT3xdZwUBTJwkK29ObMuNl5lrS2rHlKJkJk054huJV4Vb9gm"}";
      }
    ];
  };

  systemd.services.unison-cloud-demo-hello = {
    description = "Deploy the demo's hello-world service as the demo user";
    wantedBy = ["multi-user.target"];
    wants = ["caddy.service" "unison-cloud-api.service"];
    after = ["caddy.service" "unison-cloud-api.service"] ++ map (node: node.unit) cfg.internal.nimbusNodes;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe deployHello;
      TimeoutStartSec = "15min";
    };
  };

  networking.firewall.allowedTCPPorts = [cfg.ingress.port];
}
