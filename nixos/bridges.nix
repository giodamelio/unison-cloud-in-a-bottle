{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  ns = cfg.network.namespace;
  ports = lib.mapAttrsToList (_: bridge: bridge.port) cfg.network.hostBridges;
in {
  options.services.unison-cloud.network.hostBridges = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        target = lib.mkOption {
          type = lib.types.str;
          example = "127.0.0.1:1411";
          description = ''
            `host:port` or an absolute unix socket path, dialled from the host's network
            namespace by a forwarder running as a dynamic user. A unix socket must be
            connectable by any user.
          '';
        };

        port = lib.mkOption {
          type = lib.types.port;
          description = "TCP port the bridge listens on, on 127.0.0.1 inside the namespace.";
        };

        users = lib.mkOption {
          type = lib.types.nonEmptyListOf lib.types.str;
          description = "Namespace users that may connect to the bridge. The namespace firewall rejects everyone else, root included.";
        };
      };
    });
    default = {};
    description = ''
      Scoped paths from the namespace to services that only the host can reach, such as a
      login provider on the host's loopback or an S3 store on a private network.

      The listening socket is bound inside the namespace, and the forwarder that accepts
      its connections runs in the host's namespace, so nothing is exposed on the host or
      in the filesystem. The forwarder is plain TCP, so the client and the target still
      authenticate each other; only list targets that check credentials.
    '';
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.length ports == lib.length (lib.unique ports);
        message = "services.unison-cloud: every network.hostBridges entry needs its own port.";
      }
    ];

    # sockets.target comes before the namespace exists, so these sockets order themselves
    # after it instead, and after the firewall that enforces `users`.
    systemd.sockets = lib.mapAttrs' (name: bridge:
      lib.nameValuePair "unison-cloud-bridge-${name}" {
        description = "Unison Cloud bridge ${name}, listening inside the namespace";
        wantedBy = ["multi-user.target"];
        bindsTo = ["unison-cloud-netns.service" "unison-cloud-netns-firewall.service"];
        after = ["unison-cloud-netns.service" "unison-cloud-netns-firewall.service"];
        conflicts = ["shutdown.target"];
        before = ["shutdown.target"];
        unitConfig.DefaultDependencies = false;
        socketConfig = {
          ListenStream = "127.0.0.1:${toString bridge.port}";
          NetworkNamespacePath = "/run/netns/${ns}";
        };
      })
    cfg.network.hostBridges;

    systemd.services = lib.mapAttrs' (name: bridge:
      lib.nameValuePair "unison-cloud-bridge-${name}" {
        description = "Unison Cloud bridge ${name}, forwarding to ${bridge.target}";
        requires = ["unison-cloud-bridge-${name}.socket"];
        after = ["unison-cloud-bridge-${name}.socket"];
        serviceConfig = {
          ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${bridge.target}";
          DynamicUser = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          ProtectProc = "invisible";
          ProcSubset = "pid";
          NoNewPrivileges = true;
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = ["@system-service" "~@privileged @resources"];
          RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
          CapabilityBoundingSet = [""];
        };
      })
    cfg.network.hostBridges;
  };
}
