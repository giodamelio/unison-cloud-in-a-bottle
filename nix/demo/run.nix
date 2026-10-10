{
  writeShellApplication,
  coreutils,
  curl,
  socat,
  nixos,
}: let
  inherit (nixos.config.system.build) vm;
  inherit (nixos.config.networking) hostName;
  cfg = nixos.config.services.unison-cloud;
  url = cfg.internal.publicUrl;
  port = toString cfg.ingress.port;
in
  writeShellApplication {
    name = "unison-cloud-demo";
    runtimeInputs = [coreutils curl socat];
    text = ''
      persist=
      for arg in "$@"; do
        case $arg in
          --persist) persist=1 ;;
          -h | --help)
            echo "usage: unison-cloud-demo [--persist]"
            echo "  --persist  keep the VM's disk in ./unison-cloud-demo.qcow2 and reuse it on the next run"
            exit 0
            ;;
          *)
            echo "unison-cloud-demo: unknown argument: $arg" >&2
            exit 2
            ;;
        esac
      done

      die() {
        echo "unison-cloud-demo: $*" >&2
        exit 1
      }

      # Without KVM, QEMU emulates the CPU and the stack takes far too long to come up.
      if [[ ! -e /dev/kvm ]]; then
        die "/dev/kvm does not exist. Enable hardware virtualisation (VT-x or AMD-V) in the firmware and load the kvm_intel or kvm_amd module."
      fi
      if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
        die "/dev/kvm is not readable and writable by $(id -un). Add yourself to its group ($(stat -c %G /dev/kvm)) and log in again."
      fi

      if (exec 3<>/dev/tcp/127.0.0.1/${port}) 2>/dev/null; then
        die "something already listens on 127.0.0.1:${port}, which the demo's URLs need. Stop it and run the demo again."
      fi

      state=$(mktemp -d -t unison-cloud-demo.XXXXXXXXXX)
      if [[ -n $persist ]]; then
        disk=$PWD/unison-cloud-demo.qcow2
      else
        disk=$state/disk.qcow2
      fi
      console=$state/console.log
      vm_pid=

      # shellcheck disable=SC2329 # called from the EXIT trap
      stop_vm() {
        [[ -n $vm_pid ]] && kill -0 "$vm_pid" 2>/dev/null || return 0
        if [[ -n $persist ]]; then
          echo "Shutting the VM down (keeping $disk); press Ctrl-C again to kill it..."
          echo system_powerdown | socat - "UNIX-CONNECT:$state/monitor" >/dev/null 2>&1 || true
          for _ in $(seq 120); do
            kill -0 "$vm_pid" 2>/dev/null || return 0
            sleep 1
          done
          echo "unison-cloud-demo: the VM did not shut down within 2 minutes; killing it." >&2
        fi
        kill "$vm_pid" 2>/dev/null || true
        wait "$vm_pid" 2>/dev/null || true
      }

      # shellcheck disable=SC2329 # the EXIT trap
      cleanup() {
        # Without this, a second Ctrl-C during the shutdown would leave QEMU running,
        # because background jobs ignore SIGINT.
        trap 'kill "$vm_pid" 2>/dev/null || true' INT TERM HUP
        stop_vm
        rm -rf "$state"
      }
      trap cleanup EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM
      trap 'exit 129' HUP

      echo "Booting the Unison Cloud demo VM (console log: $console)..."
      # The run script only uses TMPDIR, which holds /tmp/xchg's host side, when USE_TMPDIR is set.
      NIX_DISK_IMAGE=$disk TMPDIR=$state USE_TMPDIR=1 \
        QEMU_OPTS="-monitor unix:$state/monitor,server,nowait" \
        ${vm}/bin/run-${hostName}-vm </dev/null >"$console" 2>&1 &
      vm_pid=$!

      http_status() {
        curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" || true
      }

      started=$SECONDS
      until [[ $(http_status ${url.ui}/) == 200 &&
        $(http_status ${url.api}/dex/.well-known/openid-configuration) == 200 &&
        $(http_status ${url.api}/v2/account) == 401 &&
        $(http_status ${url.apps}/) != @(000|5??) &&
        -s $state/xchg/dex-admin-password ]]; do
        if ! kill -0 "$vm_pid" 2>/dev/null; then
          vm_pid=
          tail -n 40 "$console" >&2
          die "the VM exited before the stack came up; its console output is above."
        fi
        if ((SECONDS - started > 900)); then
          tail -n 40 "$console" >&2
          die "the stack did not answer within 15 minutes; the end of the console log is above."
        fi
        sleep 2
      done

      if [[ -n $persist ]]; then
        on_exit="(the disk stays in $disk)"
      else
        on_exit="and delete its disk"
      fi

      cat <<EOF

      Unison Cloud is up after $((SECONDS - started))s.

        UI:     ${url.ui}
        API:    ${url.api}
        Login:  demo / demo
        Admin:  admin@${cfg.domains.api} / $(cat "$state/xchg/dex-admin-password")
                (inside the VM: ${cfg.stateDir}/secrets/dex-admin-password)

      Deploy from ucm:
        1. In another terminal, enter this flake's demo shell (nix develop <flake>#demo).
           It provides ucm and points the cloud client at this VM.
        2. Log in once, as demo / demo in the browser window ucm opens:
             UNISON_SHARE_HOST=${url.api} ucm
             auth.login
           Then quit that ucm. The login is stored for ${cfg.domains.api}:${toString cfg.ingress.port} only,
           so your Share login is untouched.
        3. Start ucm normally and run your Cloud.run program.

      Console log: $console
      Press Ctrl-C to stop the VM $on_exit.
      EOF

      wait "$vm_pid" || true
      vm_pid=
      tail -n 40 "$console" >&2
      die "the VM exited; the end of its console log is above."
    '';
  }
