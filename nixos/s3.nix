{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  user = "unison-cloud-s3";
  bucketsDir = "${cfg.stateDir}/s3/buckets";
  metadataDir = "${cfg.stateDir}/s3/metadata";
  secrets = "${cfg.stateDir}/secrets";
  domain = cfg.internal.s3Domain;
in {
  options.services.unison-cloud = {
    s3.buckets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = ["unison-cloud-services" "unison-cloud-user-blobs"];
      description = "Buckets cloud-api and nimbus store deployed code and user blobs in.";
    };

    internal = {
      s3Domain = lib.mkOption {
        type = lib.types.str;
        internal = true;
        readOnly = true;
        default = "s3.unison-cloud.internal";
        description = "Base domain for virtual-host bucket addressing, which nimbus requires.";
      };

      s3Port = lib.mkOption {
        type = lib.types.port;
        internal = true;
        readOnly = true;
        default = 7070;
        description = "Port versitygw listens on, on the namespace loopback.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${user} = {
      isSystemUser = true;
      group = user;
    };
    users.groups.${user} = {};

    networking.hosts."127.0.0.1" = [domain] ++ map (bucket: "${bucket}.${domain}") cfg.s3.buckets;

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
      // lib.genAttrs (map (bucket: "${bucketsDir}/${bucket}") cfg.s3.buckets) (_: {
        d = {
          inherit user;
          group = user;
          mode = "0700";
        };
      });

    systemd.services.unison-cloud-s3 = lib.mkMerge [
      cfg.internal.inNamespace
      {
        description = "Unison Cloud S3 (versitygw)";
        wantedBy = ["multi-user.target"];
        requires = ["unison-cloud-secrets.service"];
        after = ["unison-cloud-secrets.service"];
        serviceConfig = {
          User = user;
          Group = user;
          LoadCredential = [
            "access-key-id:${secrets}/s3-access-key-id"
            "secret-access-key:${secrets}/s3-secret-access-key"
          ];
          # The sidecar directory holds object metadata, so the data directory needs no
          # extended-attribute support.
          ExecStart = pkgs.writeShellScript "unison-cloud-s3" ''
            ROOT_ACCESS_KEY=$(< "$CREDENTIALS_DIRECTORY/access-key-id") \
            ROOT_SECRET_KEY=$(< "$CREDENTIALS_DIRECTORY/secret-access-key") \
              exec ${lib.getExe pkgs.versitygw} \
                --port 127.0.0.1:${toString cfg.internal.s3Port} \
                --virtual-domain ${domain} \
                --quiet \
                posix --sidecar ${metadataDir} ${bucketsDir}
          '';
        };
      }
    ];
  };
}
