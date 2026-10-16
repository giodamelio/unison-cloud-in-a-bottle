{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  lokiUser = "unison-cloud-loki";
  lokiDir = "${cfg.stateDir}/loki";
  shipperUser = "unison-cloud-log-shipper";
  shipperDir = "${cfg.stateDir}/log-shipper";

  lokiConfig = pkgs.writeText "unison-cloud-loki.json" (builtins.toJSON {
    auth_enabled = false;
    server = {
      http_listen_address = "127.0.0.1";
      http_listen_port = cfg.internal.lokiPort;
      grpc_listen_address = "127.0.0.1";
      grpc_listen_port = cfg.internal.lokiGrpcPort;
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

  # cloud-api queries `{job="nomad_allocs", namespace="user", task_name=<cluster's
  # loki_task_name>} | userId=<user id>`, the labels upstream's Nomad log collection set.
  # nimbus writes one JSON object per line, prefixed with a zero-width space; the lines
  # about a user's job carry `userId` as the user's UUID in hex without dashes, which is
  # also how cloud-api renders it in the query. The zero-width space is upstream's line
  # separator for ingestion, not part of the line: the web UI JSON.parses each stored line
  # and silently drops any it cannot parse, so it is stripped before shipping.
  shipperConfigJson = pkgs.writeText "unison-cloud-log-shipper.json" (builtins.toJSON {
    data_dir = shipperDir;
    sources.nimbus = {
      type = "journald";
      journalctl_path = lib.getExe' config.systemd.package "journalctl";
      include_units = map (node: node.unit) cfg.internal.nimbusNodes;
    };
    transforms.user_lines = {
      type = "remap";
      inputs = ["nimbus"];
      drop_on_abort = true;
      source = ''
        line = replace(string!(.message), r'^\x{200B}', "")
        parsed, err = parse_json(line)
        if err != null || !is_object(parsed) { abort }
        user_id = parsed.userId
        if !is_string(user_id) { abort }
        . = {"message": line, "timestamp": .timestamp, "userId": user_id}
      '';
    };
    sinks.loki = {
      type = "loki";
      inputs = ["user_lines"];
      endpoint = cfg.logs.lokiUrl;
      encoding.codec = "text";
      labels = {
        job = "nomad_allocs";
        namespace = "user";
        task_name = "nimbus";
      };
      structured_metadata.userId = "{{ userId }}";
      out_of_order_action = "accept";
      # Loki needs a few seconds before it reports ready; Vector retries sends anyway.
      healthcheck.enabled = false;
    };
  });
  shipperConfig = pkgs.runCommand "unison-cloud-log-shipper.json" {} ''
    ${lib.getExe pkgs.vector} validate --no-environment ${shipperConfigJson}
    cp ${shipperConfigJson} $out
  '';
in {
  options.services.unison-cloud.internal.lokiPort = lib.mkOption {
    type = lib.types.port;
    internal = true;
    readOnly = true;
    default = 24152;
    description = "HTTP port of the bundled Loki, on loopback.";
  };

  options.services.unison-cloud.internal.lokiGrpcPort = lib.mkOption {
    type = lib.types.port;
    internal = true;
    readOnly = true;
    default = 24153;
    description = "gRPC port of the bundled Loki, on loopback.";
  };

  config = lib.mkIf cfg.enable {
    services.unison-cloud.logs.lokiUrl = lib.mkDefault "http://127.0.0.1:${toString cfg.internal.lokiPort}";

    users.users.${lokiUser} = {
      isSystemUser = true;
      group = lokiUser;
    };
    users.groups.${lokiUser} = {};

    users.users.${shipperUser} = {
      isSystemUser = true;
      group = shipperUser;
    };
    users.groups.${shipperUser} = {};

    systemd.tmpfiles.settings.unison-cloud-loki = {
      ${lokiDir}.d = {
        user = lokiUser;
        group = lokiUser;
        mode = "0700";
      };
      ${shipperDir}.d = {
        user = shipperUser;
        group = shipperUser;
        mode = "0700";
      };
    };

    systemd.services.unison-cloud-loki = lib.mkMerge [
      cfg.internal.sandbox
      {
        description = "Unison Cloud log store (Loki)";
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          User = lokiUser;
          Group = lokiUser;
          WorkingDirectory = lokiDir;
          ExecStart = "${lib.getExe' pkgs.grafana-loki "loki"} -config.file=${lokiConfig}";
          Restart = "on-failure";
        };
      }
    ];

    systemd.services.unison-cloud-log-shipper = lib.mkIf cfg.nimbus.enable (lib.mkMerge [
      cfg.internal.sandbox
      {
        description = "Ship nimbus's logs to the Unison Cloud Loki (Vector)";
        wantedBy = ["multi-user.target"];
        requires = ["unison-cloud-loki.service"];
        after = ["unison-cloud-loki.service"];
        serviceConfig = {
          User = shipperUser;
          Group = shipperUser;
          SupplementaryGroups = ["systemd-journal"];
          ExecStart = "${lib.getExe pkgs.vector} --config-json ${shipperConfig}";
          Restart = "on-failure";
        };
      }
    ]);
  };
}
