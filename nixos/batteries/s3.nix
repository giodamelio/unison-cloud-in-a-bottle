{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  battery = cfg.batteries.s3;
  user = "unison-cloud-s3";
  bucketsDir = "${cfg.stateDir}/s3/buckets";
  metadataDir = "${cfg.stateDir}/s3/metadata";
  # Base domain for virtual-host bucket addressing, which nimbus requires.
  domain = "s3.unison-cloud.internal";
  buckets = lib.attrValues cfg.s3.buckets;
  clients =
    lib.optional cfg.cloudApi.enable "unison-cloud-api.service"
    ++ lib.optionals cfg.nimbus.enable (map (node: node.unit) cfg.internal.nimbusNodes);
in {
  options.services.unison-cloud.batteries.s3 = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run versitygw on loopback as the S3 store, with both buckets, and generate its keys.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 24151;
      description = "Port of the bundled S3 store, on loopback.";
    };
  };

  config = lib.mkIf (cfg.enable && battery.enable) {
    services.unison-cloud.s3 = {
      host = domain;
      inherit (battery) port;
      https = false;
    };

    users.users.${user} = {
      isSystemUser = true;
      group = user;
    };
    users.groups.${user} = {};

    # AWS-shaped, so SDKs accept it.
    services.unison-cloud.internal.secretGenerators = {
      s3-access-key-id = ''printf AKIA%s "$(openssl rand -hex 8 | tr a-f A-F)"'';
      s3-secret-access-key = "openssl rand -hex 20";
    };

    networking.hosts."127.0.0.1" = [domain] ++ map (bucket: "${bucket}.${domain}") buckets;

    # A bucket in the posix backend is just a top-level directory.
    systemd.tmpfiles.settings.unison-cloud-s3 =
      {
        "${cfg.stateDir}/s3".d = {
          inherit user;
          group = user;
          mode = "0700";
        };
        ${bucketsDir}.d = {
          inherit user;
          group = user;
          mode = "0700";
        };
        ${metadataDir}.d = {
          inherit user;
          group = user;
          mode = "0700";
        };
      }
      // lib.genAttrs (map (bucket: "${bucketsDir}/${bucket}") buckets) (_: {
        d = {
          inherit user;
          group = user;
          mode = "0700";
        };
      });

    systemd.services.unison-cloud-s3 = lib.mkMerge [
      cfg.internal.sandbox
      {
        description = "Unison Cloud S3 (versitygw)";
        wantedBy = ["multi-user.target"];
        requires = ["unison-cloud-secrets.service"];
        after = ["unison-cloud-secrets.service"];
        requiredBy = clients;
        before = clients;
        serviceConfig = lib.mkMerge [
          (cfg.internal.loadSecrets ["s3-access-key-id" "s3-secret-access-key"])
          {
            User = user;
            Group = user;
            IPAddressDeny = "any";
            IPAddressAllow = "localhost";
            # The sidecar directory holds object metadata, so the data directory needs no
            # extended-attribute support.
            ExecStart = pkgs.writeShellScript "unison-cloud-s3" ''
              ROOT_ACCESS_KEY=$(< "$CREDENTIALS_DIRECTORY/s3-access-key-id") \
              ROOT_SECRET_KEY=$(< "$CREDENTIALS_DIRECTORY/s3-secret-access-key") \
                exec ${lib.getExe pkgs.versitygw} \
                  --port 127.0.0.1:${toString battery.port} \
                  --virtual-domain ${domain} \
                  --quiet \
                  posix --sidecar ${metadataDir} ${bucketsDir}
            '';
          }
        ];
      }
    ];
  };
}
