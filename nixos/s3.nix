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
  ext = cfg.s3.external;
in {
  options.services.unison-cloud = {
    s3 = {
      buckets = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        readOnly = true;
        default = ["unison-cloud-services" "unison-cloud-user-blobs"];
        description = "Buckets cloud-api and nimbus store deployed code and user blobs in. With an external S3, create them yourself.";
      };

      bundled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Run versitygw inside the namespace as the S3 store. With `false`, use
          `s3.external` and supply the credentials as `secrets.files.s3-access-key-id` and
          `s3-secret-access-key`.

          nimbus reaches S3 directly, never through the outbound proxy, and an external S3
          usually has no fixed address to allowlist. So with an external S3 the nimbus and
          cloud-api users may send traffic out of the namespace, which lets hosted code reach
          the public internet without the proxy. Private ranges and the host stay blocked
          unless listed in `egress.allowedDestinations`.
        '';
      };

      external = {
        host = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "s3.us-west-2.amazonaws.com";
          description = "S3 endpoint host. nimbus addresses buckets as `<bucket>.<host>`, so the store must support virtual-host addressing.";
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 443;
        };

        https = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };

        region = lib.mkOption {
          type = lib.types.str;
          default = "us-east-1";
        };
      };
    };

    internal = {
      s3 = lib.mkOption {
        type = lib.types.attrs;
        internal = true;
        readOnly = true;
        default =
          if cfg.s3.bundled
          then {
            host = domain;
            port = cfg.internal.s3Port;
            https = false;
            region = "us-east-1";
            unit = "unison-cloud-s3.service";
          }
          else {
            inherit (ext) host port https region;
            unit = null;
          };
        description = "Where cloud-api and nimbus reach S3.";
      };

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

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.s3.bundled || (ext.host != null && cfg.secrets.files ? s3-access-key-id && cfg.secrets.files ? s3-secret-access-key);
          message = "services.unison-cloud: with s3.bundled = false, set s3.external.host and supply secrets.files.s3-access-key-id and s3-secret-access-key.";
        }
      ];
    }
    (lib.mkIf cfg.s3.bundled {
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
    })
  ]);
}
