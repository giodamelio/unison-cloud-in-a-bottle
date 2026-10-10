{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  user = "unison-cloud-consul";
  dataDir = "${cfg.stateDir}/consul";

  configFile = pkgs.writeText "unison-cloud-consul.json" (builtins.toJSON {
    server = true;
    bootstrap_expect = 1;
    data_dir = dataDir;
    bind_addr = "127.0.0.1";
    client_addr = "127.0.0.1";
    ports = {
      http = cfg.internal.consulPort;
      dns = -1;
      grpc = -1;
      grpc_tls = -1;
    };
    disable_update_check = true;
    services = cfg.internal.consulServices;
  });
in {
  options.services.unison-cloud = {
    consul.package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.consul;
      defaultText = lib.literalExpression "pkgs.consul";
      description = ''
        Consul package for the bundled single-node server. nixpkgs marks Consul unfree
        (BSL 1.1), so allow it, for example with
        `nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "consul";`.
      '';
    };

    internal = {
      consulPort = lib.mkOption {
        type = lib.types.port;
        internal = true;
        readOnly = true;
        default = 8500;
        description = "HTTP port of the bundled Consul, on the namespace loopback.";
      };

      consulServices = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        internal = true;
        default = [];
        description = "Service definitions registered in the Consul server's own configuration.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${user} = {
      isSystemUser = true;
      group = user;
    };
    users.groups.${user} = {};

    systemd.tmpfiles.settings.unison-cloud-consul.${dataDir}.d = {
      inherit user;
      group = user;
      mode = "0700";
    };

    systemd.services.unison-cloud-consul = lib.mkMerge [
      cfg.internal.inNamespace
      {
        description = "Unison Cloud Consul server";
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          # Consul never sends a readiness notification here; clients wait for a leader instead.
          Type = "exec";
          User = user;
          Group = user;
          ExecStart = "${lib.getExe cfg.consul.package} agent -config-file ${configFile}";
          ExecReload = "${lib.getExe' pkgs.coreutils "kill"} -HUP $MAINPID";
        };
      }
    ];
  };
}
