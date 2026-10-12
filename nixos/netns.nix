{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  ns = cfg.network.namespace;
  ip = lib.getExe' pkgs.iproute2 "ip";
in {
  options.services.unison-cloud.internal.inNamespace = lib.mkOption {
    type = lib.types.attrs;
    internal = true;
    readOnly = true;
    default = {
      bindsTo = ["unison-cloud-netns.service"];
      requires = ["unison-cloud-netns-firewall.service"];
      after = ["unison-cloud-netns.service" "unison-cloud-netns-firewall.service"];
      serviceConfig =
        {NetworkNamespacePath = "/run/netns/${ns}";}
        // lib.mapAttrs (_: lib.mkDefault) {
          # The namespace isolates TCP and UDP only. Unix sockets and files stay shared
          # with the host, so every unit gets a baseline sandbox; nimbus and cloud-api add
          # more in their own modules.
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
    description = "Unit settings that place a service inside the namespace.";
  };

  config = lib.mkIf cfg.enable {
    # A named namespace rather than PrivateNetwork=, so the egress veth can be attached to it later.
    systemd.services.unison-cloud-netns = {
      description = "Unison Cloud network namespace";
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Left behind if the host went down without stopping this unit.
        ExecStartPre = "-${ip} netns delete ${ns}";
        ExecStart = [
          "${ip} netns add ${ns}"
          "${ip} -n ${ns} link set lo up"
        ];
        ExecStop = "${ip} netns delete ${ns}";
      };
    };
  };
}
