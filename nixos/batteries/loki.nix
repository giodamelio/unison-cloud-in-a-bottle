{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  battery = cfg.batteries.loki;
  lokiUser = "unison-cloud-loki";
  lokiDir = "${cfg.stateDir}/loki";
  shipper = lib.optional cfg.nimbus.enable "unison-cloud-log-shipper.service";

  lokiConfig = pkgs.writeText "unison-cloud-loki.json" (builtins.toJSON {
    auth_enabled = false;
    server = {
      http_listen_address = "127.0.0.1";
      http_listen_port = battery.port;
      grpc_listen_address = "127.0.0.1";
      grpc_listen_port = battery.grpcPort;
      log_level = "warn";
    };
    common = {
      path_prefix = lokiDir;
      replication_factor = 1;
      instance_addr = "127.0.0.1";
      ring.kvstore.store = "inmemory";
      storage.filesystem = {
        chunks_directory = "${lokiDir}/chunks";
        rules_directory = "${lokiDir}/rules";
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
  });
in {
  options.services.unison-cloud.batteries.loki = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run Loki on loopback as the log store.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 24152;
      description = "HTTP port of the bundled Loki, on loopback.";
    };

    grpcPort = lib.mkOption {
      type = lib.types.port;
      default = 24153;
      description = "gRPC port of the bundled Loki, on loopback.";
    };
  };

  config = lib.mkIf (cfg.enable && battery.enable) {
    services.unison-cloud.logs.lokiUrl = "http://127.0.0.1:${toString battery.port}";

    users.users.${lokiUser} = {
      isSystemUser = true;
      group = lokiUser;
    };
    users.groups.${lokiUser} = {};

    systemd.tmpfiles.settings.unison-cloud-loki.${lokiDir}.d = {
      user = lokiUser;
      group = lokiUser;
      mode = "0700";
    };

    systemd.services.unison-cloud-loki = lib.mkMerge [
      cfg.internal.sandbox
      {
        description = "Unison Cloud log store (Loki)";
        wantedBy = ["multi-user.target"];
        requiredBy = shipper;
        before = shipper;
        serviceConfig = {
          User = lokiUser;
          Group = lokiUser;
          WorkingDirectory = lokiDir;
          IPAddressDeny = "any";
          IPAddressAllow = "localhost";
          ExecStart = "${lib.getExe' pkgs.grafana-loki "loki"} -config.file=${lokiConfig}";
          Restart = "on-failure";
        };
      }
    ];
  };
}
