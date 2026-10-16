{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  inherit (cfg.consul) prefix;

  # Prefix rules match plain strings, so the trailing separators keep `<prefix>2/` and
  # `<prefix>2-` out. Consul filters health results by `node:read` on each instance's
  # node, so without it cloud-api would silently see no nimbus nodes.
  policy = pkgs.writeText "unison-cloud-consul-policy.hcl" ''
    key_prefix "${prefix}/" {
      policy = "write"
    }

    service_prefix "${prefix}-" {
      policy = "write"
    }

    node_prefix "" {
      policy = "read"
    }
  '';

  serviceFiles = map (service: pkgs.writeText "unison-cloud-consul-service-${service.ID}.json" (builtins.toJSON service)) cfg.internal.consulServices;
  consulCurl = ''
    consul() {
      local method=$1 path=$2
      shift 2
      curl -sS --fail-with-body --retry 10 --retry-connrefused -X "$method" \
        -H @<(printf 'X-Consul-Token: %s\n' "$(< "$CREDENTIALS_DIRECTORY/consul-token")") \
        "${cfg.consul.address}$path" "$@"
    }
  '';
  register = pkgs.writeShellApplication {
    name = "unison-cloud-consul-register";
    runtimeInputs = [pkgs.curl];
    text = ''
      ${consulCurl}
      ${lib.concatMapStrings (file: ''
          consul PUT /v1/agent/service/register --data @${file}
        '')
        serviceFiles}
    '';
  };
  deregister = pkgs.writeShellApplication {
    name = "unison-cloud-consul-deregister";
    runtimeInputs = [pkgs.curl];
    text = ''
      ${consulCurl}
      ${lib.concatMapStrings (service: ''
          consul PUT /v1/agent/service/deregister/${service.ID}
        '')
        cfg.internal.consulServices}
    '';
  };
in {
  options.services.unison-cloud = {
    consul = {
      address = lib.mkOption {
        type = lib.types.str;
        default = "http://127.0.0.1:8500";
        description = ''
          Base URL of this host's local Consul agent, which cloud-api and the service
          registrations use over plain HTTP. Supply a token holding `consul.aclPolicy` as
          `consul-token` in `secrets.files` or `secrets.credentials`.
        '';
      };

      prefix = lib.mkOption {
        type = lib.types.strMatching "[a-z0-9-]+";
        default = "unison-cloud";
        description = ''
          Prefix of every Consul KV key (`<prefix>/`) and service name (`<prefix>-`) the
          stack uses, so it can share a cluster with other tenants. It also forms service
          names, which is why it's limited to lowercase letters, digits and dashes.
        '';
      };

      aclPolicy = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        default = policy;
        defaultText = lib.literalMD "a file with the rules for `consul.prefix`";
        description = ''
          ACL policy, in HCL, that `consul-token` needs: write on the prefixed keys and
          services, and read on every node. Create it and a token with
          `consul acl policy create -name unison-cloud -rules @<this file>` and
          `consul acl token create -policy-name unison-cloud`.
        '';
      };
    };

    internal.consulServices = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      internal = true;
      default = [];
      description = "Service definitions, in the agent API's format, registered with the local agent while `unison-cloud-consul-services` runs.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.unison-cloud-consul-services = lib.mkMerge [
      cfg.internal.sandbox
      {
        description = "Register the Unison Cloud services with the local Consul agent";
        wantedBy = ["multi-user.target"];
        requires = ["unison-cloud-secrets.service"];
        after = ["unison-cloud-secrets.service"];
        serviceConfig = lib.mkMerge [
          (cfg.internal.loadSecrets ["consul-token"])
          {
            Type = "oneshot";
            RemainAfterExit = true;
            DynamicUser = true;
            ExecStart = lib.getExe register;
            ExecStop = lib.getExe deregister;
          }
        ];
      }
    ];
  };
}
