{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  shipperUser = "unison-cloud-log-shipper";
  shipperDir = "${cfg.stateDir}/log-shipper";

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
  config = lib.mkIf (cfg.enable && cfg.nimbus.enable) {
    users.users.${shipperUser} = {
      isSystemUser = true;
      group = shipperUser;
    };
    users.groups.${shipperUser} = {};

    systemd.tmpfiles.settings.unison-cloud-log-shipper.${shipperDir}.d = {
      user = shipperUser;
      group = shipperUser;
      mode = "0700";
    };

    systemd.services.unison-cloud-log-shipper = lib.mkMerge [
      cfg.internal.sandbox
      {
        description = "Ship nimbus's logs to Loki (Vector)";
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          User = shipperUser;
          Group = shipperUser;
          SupplementaryGroups = ["systemd-journal"];
          ExecStart = "${lib.getExe pkgs.vector} --config-json ${shipperConfig}";
          Restart = "on-failure";
        };
      }
    ];
  };
}
