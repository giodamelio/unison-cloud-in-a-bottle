{
  config,
  lib,
  ...
}: let
  cfg = config.services.unison-cloud;
in {
  options.services.unison-cloud.s3 = {
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

    host = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "s3.garage.example.com";
      description = ''
        S3 endpoint host. nimbus addresses buckets as `<bucket>.<host>`, so the store must
        support virtual-host addressing for this name, and every bucket's name must
        resolve on this host. Create both `s3.buckets` there yourself, and supply the
        credentials as `s3-access-key-id` and `s3-secret-access-key` in `secrets.files` or
        `secrets.credentials`.
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

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.s3.host != null;
        message = "services.unison-cloud: set s3.host to the S3 store's endpoint host.";
      }
    ];
  };
}
