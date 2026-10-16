{lib, ...}: {
  options.services.unison-cloud.internal.sandbox = lib.mkOption {
    type = lib.types.attrs;
    internal = true;
    readOnly = true;
    default = {
      serviceConfig = lib.mapAttrs (_: lib.mkDefault) {
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        NoNewPrivileges = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
      };
    };
    description = "Unit settings for the baseline sandbox every service gets; nimbus and cloud-api add more in their own modules.";
  };

  options.services.unison-cloud.internal.hostIsolation = lib.mkOption {
    type = lib.types.attrs;
    internal = true;
    readOnly = true;
    default = {
      ProtectSystem = "strict";
      ProtectProc = "invisible";
      CapabilityBoundingSet = [""];
      UMask = "0077";
      # An allowlist rather than a denylist: /run and /var start empty, so the host's
      # sockets (Postgres, D-Bus, nscd, other services) and world-readable state don't
      # exist here at all. A unit binds back the few paths it needs.
      TemporaryFileSystem = ["/run" "/var"];
      # With systemd-resolved, /etc/resolv.conf links into /run, so without these the
      # unit has no resolver at all.
      BindReadOnlyPaths = ["-/run/systemd/resolve/stub-resolv.conf" "-/run/systemd/resolve/resolv.conf"];
      InaccessiblePaths = ["-/nix/var" "-/boot" "-/mnt" "-/media" "-/srv" "-/opt"];
    };
    description = "Unit settings that hide the host's sockets and state from services that face hosted code.";
  };
}
