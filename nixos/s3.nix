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
  domain = cfg.internal.s3Domain;
  ext = cfg.s3.external;
  buckets = lib.attrValues cfg.s3.buckets;
  credentialsSupplied = name: cfg.secrets.files ? ${name} || cfg.secrets.credentials ? ${name};
in {
  options.services.unison-cloud = {
    s3 = {
      buckets = {
        services = lib.mkOption {
          type = lib.types.str;
          default = "unison-cloud-services";
          description = "Bucket cloud-api and nimbus store deployed code in.";
        };

        userBlobs = lib.mkOption {
          type = lib.types.str;
          default = "unison-cloud-user-blobs";
          description = "Bucket nimbus stores user blobs in.";
        };
      };

      bundled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Run versitygw on loopback as the S3 store. With `false`, use the store described
          by `s3.external`, create both `s3.buckets` there yourself, and supply the
          credentials as `s3-access-key-id` and `s3-secret-access-key` in `secrets.files`
          or `secrets.credentials`.
        '';
      };

      external = {
        host = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "s3.garage.example.com";
          description = ''
            S3 endpoint host. nimbus addresses buckets as `<bucket>.<host>`, so the store
            must support virtual-host addressing for this name, and every bucket's name
            must resolve on this host.
          '';
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 443;
          description = "Port of the S3 endpoint.";
        };

        https = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether the store speaks HTTPS. The certificate must be valid for `host` and `*.host`.";
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
        description = "Where cloud-api and nimbus reach S3, and the unit that serves it.";
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
        default = 24151;
        description = "Port of the bundled S3 store, on loopback.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.s3.bundled || (ext.host != null && credentialsSupplied "s3-access-key-id" && credentialsSupplied "s3-secret-access-key");
          message = "services.unison-cloud: with s3.bundled = false, set s3.external.host and supply s3-access-key-id and s3-secret-access-key through secrets.files or secrets.credentials.";
        }
      ];
    }
    (lib.mkIf cfg.s3.bundled {
      users.users.${user} = {
        isSystemUser = true;
        group = user;
      };
      users.groups.${user} = {};

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
          serviceConfig = lib.mkMerge [
            (cfg.internal.loadSecrets ["s3-access-key-id" "s3-secret-access-key"])
            {
              User = user;
              Group = user;
              # The sidecar directory holds object metadata, so the data directory needs no
              # extended-attribute support.
              ExecStart = pkgs.writeShellScript "unison-cloud-s3" ''
                ROOT_ACCESS_KEY=$(< "$CREDENTIALS_DIRECTORY/s3-access-key-id") \
                ROOT_SECRET_KEY=$(< "$CREDENTIALS_DIRECTORY/s3-secret-access-key") \
                  exec ${lib.getExe pkgs.versitygw} \
                    --port 127.0.0.1:${toString cfg.internal.s3Port} \
                    --virtual-domain ${domain} \
                    --quiet \
                    posix --sidecar ${metadataDir} ${bucketsDir}
              '';
            }
          ];
        }
      ];
    })
  ]);
}
