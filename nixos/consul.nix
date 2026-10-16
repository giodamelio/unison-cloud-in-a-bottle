{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  user = "unison-cloud-consul";
  dataDir = "${cfg.stateDir}/consul";
  bundledAddress = "http://127.0.0.1:${toString cfg.internal.consulPort}";
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

  # What a client agent needs to register its own node and sync its services.
  agentPolicy = pkgs.writeText "unison-cloud-consul-agent-policy.hcl" ''
    node_prefix "" {
      policy = "write"
    }

    service_prefix "" {
      policy = "read"
    }
  '';

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
    acl = {
      enabled = true;
      default_policy = "deny";
    };
  });

  # The tokens are secrets, so they reach Consul in a config file written at start
  # instead of the one in the Nix store.
  writeTokens = pkgs.writeShellScript "unison-cloud-consul-tokens" ''
    ${lib.getExe pkgs.jq} -n \
      --rawfile management "$CREDENTIALS_DIRECTORY/consul-management-token" \
      --rawfile agent "$CREDENTIALS_DIRECTORY/consul-agent-token" \
      '{acl: {tokens: {initial_management: ($management | rtrimstr("\n")), agent: ($agent | rtrimstr("\n"))}}}' \
      > "$RUNTIME_DIRECTORY/tokens.json"
  '';

  # Only the bundled server's initial management token can create ACL objects, and it's
  # used for nothing else. The tokens' secret IDs are the generated secrets, so a token
  # exists once and every later boot only refreshes the policies.
  aclSetup = pkgs.writeShellApplication {
    name = "unison-cloud-consul-acl";
    runtimeInputs = [pkgs.curl pkgs.jq];
    text = ''
      creds=$CREDENTIALS_DIRECTORY

      # The header comes from a pipe so no token appears in a command line.
      consul() {
        local token=$1 method=$2 path=$3
        shift 3
        curl -sS --fail-with-body -X "$method" \
          -H @<(printf 'X-Consul-Token: %s\n' "$(< "$creds/$token")") \
          "${bundledAddress}$path" "$@"
      }

      until consul consul-management-token GET /v1/acl/token/self -o /dev/null 2> /dev/null; do
        sleep 1
      done

      upsert_policy() {
        local name=$1 rules=$2 body id
        body=$(jq -n --arg name "$name" --rawfile rules "$rules" '{Name: $name, Rules: $rules}')
        if id=$(consul consul-management-token GET "/v1/acl/policy/name/$name" 2> /dev/null | jq -er .ID 2> /dev/null); then
          consul consul-management-token PUT "/v1/acl/policy/$id" --data "$body" > /dev/null
        else
          consul consul-management-token PUT /v1/acl/policy --data "$body" > /dev/null
        fi
      }

      ensure_token() {
        local token=$1 policy=$2 description=$3
        if ! consul "$token" GET /v1/acl/token/self -o /dev/null 2> /dev/null; then
          jq -n --rawfile secret "$creds/$token" --arg policy "$policy" --arg description "$description" \
            '{SecretID: ($secret | rtrimstr("\n")), Description: $description, Policies: [{Name: $policy}]}' |
            consul consul-management-token PUT /v1/acl/token --data @- > /dev/null
        fi
      }

      upsert_policy unison-cloud ${policy}
      upsert_policy unison-cloud-agent ${agentPolicy}
      ensure_token consul-token unison-cloud "Unison Cloud cloud-api and service registrations"
      ensure_token consul-agent-token unison-cloud-agent "Unison Cloud Consul agent"
    '';
  };

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
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.consul;
        defaultText = lib.literalExpression "pkgs.consul";
        description = ''
          Consul package for the bundled single-node server. nixpkgs marks Consul unfree
          (BSL 1.1), so allow it, for example with
          `nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "consul";`.
        '';
      };

      bundled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Run a single-node Consul server on loopback, with ACLs on and every
          request denied by default. It creates the `consul.aclPolicy` policy and the
          `consul-token` token itself at boot, so `consul-token` must be a UUID if you
          supply it.

          With `false`, point `consul.address` at the host's local Consul agent, and
          supply a token holding `consul.aclPolicy` as `consul-token` in `secrets.files`
          or `secrets.credentials`.
        '';
      };

      address = lib.mkOption {
        type = lib.types.str;
        default = bundledAddress;
        example = "http://127.0.0.1:8500";
        description = "Base URL of the Consul agent cloud-api and the service registrations use.";
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
          services, and read on every node. For an external cluster, create it and a
          token with `consul acl policy create -name unison-cloud -rules @<this file>` and
          `consul acl token create -policy-name unison-cloud`.
        '';
      };
    };

    internal = {
      consulPort = lib.mkOption {
        type = lib.types.port;
        internal = true;
        readOnly = true;
        default = 8500;
        description = "HTTP port of the bundled Consul, on loopback.";
      };

      consulServices = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        internal = true;
        default = [];
        description = "Service definitions, in the agent API's format, registered with the local agent while `unison-cloud-consul-services` runs.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
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
    }

    (lib.mkIf cfg.consul.bundled {
      users.users.${user} = {
        isSystemUser = true;
        group = user;
      };
      users.groups.${user} = {};

      # The server creates its tokens with these as their secret IDs, which must be UUIDs.
      services.unison-cloud.internal.secretGenerators = lib.genAttrs ["consul-token" "consul-management-token" "consul-agent-token"] (_: "cat /proc/sys/kernel/random/uuid");

      systemd.tmpfiles.settings.unison-cloud-consul.${dataDir}.d = {
        inherit user;
        group = user;
        mode = "0700";
      };

      systemd.services = {
        unison-cloud-consul = lib.mkMerge [
          cfg.internal.sandbox
          {
            description = "Unison Cloud Consul server";
            wantedBy = ["multi-user.target"];
            requires = ["unison-cloud-secrets.service"];
            after = ["unison-cloud-secrets.service"];
            serviceConfig = lib.mkMerge [
              (cfg.internal.loadSecrets ["consul-management-token" "consul-agent-token"])
              {
                # Consul never sends a readiness notification here; clients wait for a leader instead.
                Type = "exec";
                User = user;
                Group = user;
                RuntimeDirectory = "unison-cloud-consul";
                RuntimeDirectoryMode = "0700";
                ExecStartPre = writeTokens;
                ExecStart = "${lib.getExe cfg.consul.package} agent -config-file ${configFile} -config-file %t/unison-cloud-consul/tokens.json";
                ExecReload = "${lib.getExe' pkgs.coreutils "kill"} -HUP $MAINPID";
              }
            ];
          }
        ];

        unison-cloud-consul-acl = lib.mkMerge [
          cfg.internal.sandbox
          {
            description = "Create the Unison Cloud Consul ACL policies and tokens";
            requires = ["unison-cloud-consul.service"];
            after = ["unison-cloud-consul.service"];
            serviceConfig = lib.mkMerge [
              (cfg.internal.loadSecrets ["consul-management-token" "consul-agent-token" "consul-token"])
              {
                Type = "oneshot";
                RemainAfterExit = true;
                DynamicUser = true;
                TimeoutStartSec = "2min";
                ExecStart = lib.getExe aclSetup;
              }
            ];
          }
        ];

        unison-cloud-consul-services = {
          requires = ["unison-cloud-consul-acl.service"];
          after = ["unison-cloud-consul-acl.service"];
        };

        unison-cloud-api = lib.mkIf cfg.cloudApi.enable {
          requires = ["unison-cloud-consul-acl.service"];
          after = ["unison-cloud-consul-acl.service"];
        };
      };
    })
  ]);
}
