{
  writeShellApplication,
  writeText,
  runtimeShell,
  coreutils,
  ucm,
  nixos,
}: let
  cfg = nixos.config.services.unison-cloud;
  api = cfg.internal.publicUrl.api;
  # ucm stores `auth.login` credentials under the codeserver's host and port, which is
  # what the cloud client's UNISON_CLOUD_CREDENTIALS_HOST has to name.
  credentialsHost = "${cfg.domains.api}:${toString cfg.ingress.port}";

  transcript = writeText "unison-cloud-demo-login.md" ''
    ```ucm
    scratch/main> auth.login
    ```
  '';
in
  writeShellApplication {
    name = "unison-cloud-demo-login";
    runtimeInputs = [coreutils ucm];
    text = ''
      # ucm writes <transcript>.output.md next to the transcript, so it can't run from the store.
      dir=$(mktemp -d -t unison-cloud-demo-login.XXXXXXXXXX)
      ucm_pid=
      cleanup() {
        if [[ -n $ucm_pid ]]; then kill "$ucm_pid" 2>/dev/null || true; fi
        rm -rf "$dir"
      }
      trap cleanup EXIT
      cp ${transcript} "$dir/login.md"

      # In a transcript ucm prints nothing until it finishes, and auth.login waits for the
      # browser. So ucm's xdg-open is this shim: it hands the login URL to the script to
      # print, then opens it with the real xdg-open when there is one.
      mkdir "$dir/bin"
      real_xdg_open=$(command -v xdg-open || true)
      cat > "$dir/bin/xdg-open" <<EOS
      #!${runtimeShell}
      printf '%s\\n' "\$1" > "$dir/url"
      if [ -n "$real_xdg_open" ]; then exec "$real_xdg_open" "\$1" >/dev/null 2>&1; fi
      EOS
      chmod +x "$dir/bin/xdg-open"

      # The transcript's throwaway codebase is deleted afterwards, but ucm keeps the
      # credentials in its own data directory.
      PATH=$dir/bin:$PATH UNISON_SHARE_HOST=${api} ucm transcript "$dir/login.md" > "$dir/ucm.log" 2>&1 &
      ucm_pid=$!

      until [[ -s $dir/url ]]; do
        if ! kill -0 "$ucm_pid" 2>/dev/null; then
          cat "$dir/ucm.log" >&2
          echo "unison-cloud-demo-login: ucm exited before asking for a login; its output is above." >&2
          exit 1
        fi
        sleep 0.2
      done
      cat <<EOT
      Log in as demo@unison.localhost / demo at:

        $(cat "$dir/url")

      Waiting for the login to finish...
      EOT

      if ! wait "$ucm_pid"; then
        ucm_pid=
        cat "$dir/ucm.log" >&2
        echo "unison-cloud-demo-login: the login failed; ucm's output is above." >&2
        exit 1
      fi
      ucm_pid=

      cat <<EOT

      Logged in. Deploy with ucm or any Cloud.run program, with:
        UNISON_CLOUD_HOST=${cfg.domains.api}
        UNISON_CLOUD_HTTP_PORT=${toString cfg.ingress.port}
        UNISON_CLOUD_USE_TLS=false
        UNISON_CLOUD_CREDENTIALS_HOST=${credentialsHost}
      (the demo shell, nix develop .#demo, sets these already)
      EOT
    '';
  }
