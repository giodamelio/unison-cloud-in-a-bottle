{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  battery = cfg.batteries.consul;
  user = "unison-cloud-consul";
  dataDir = "${cfg.stateDir}/consul";
  address = "http://127.0.0.1:${toString battery.port}";
  clients = ["unison-cloud-consul-services.service"] ++ lib.optional cfg.cloudApi.enable "unison-cloud-api.service";
  secret = cfg.internal.secretPath;

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
      http = battery.port;
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
      --rawfile management "${secret "consul-management-token"}" \
      --rawfile agent "${secret "consul-agent-token"}" \
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
      declare -A creds=(
        [consul-management-token]="${secret "consul-management-token"}"
        [consul-agent-token]="${secret "consul-agent-token"}"
        [consul-token]="${secret "consul-token"}"
      )

      # The header comes from a pipe so no token appears in a command line.
      consul() {
        local token=$1 method=$2 path=$3
        shift 3
        curl -sS --fail-with-body -X "$method" \
          -H @<(printf 'X-Consul-Token: %s\n' "$(< "''${creds[$token]}")") \
          "${address}$path" "$@"
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
          jq -n --rawfile secret "''${creds[$token]}" --arg policy "$policy" --arg description "$description" \
            '{SecretID: ($secret | rtrimstr("\n")), Description: $description, Policies: [{Name: $policy}]}' |
            consul consul-management-token PUT /v1/acl/token --data @- > /dev/null
        fi
      }

      upsert_policy unison-cloud ${cfg.consul.aclPolicy}
      upsert_policy unison-cloud-agent ${agentPolicy}
      ensure_token consul-token unison-cloud "Unison Cloud cloud-api and service registrations"
      ensure_token consul-agent-token unison-cloud-agent "Unison Cloud Consul agent"
    '';
  };
in {
  options.services.unison-cloud.batteries.consul = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run a single-node Consul server on loopback, with ACLs on and every request
        denied by default. It creates the `consul.aclPolicy` policy and the
        `consul-token` token itself at boot, so `consul-token` must be a UUID if you
        supply it.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.consul;
      defaultText = lib.literalExpression "pkgs.consul";
      description = ''
        Consul package for the bundled server. nixpkgs marks Consul unfree (BSL 1.1), so
        allow it, for example with
        `nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "consul";`.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8500;
      description = "HTTP port of the bundled Consul, on loopback.";
    };
  };

  config = lib.mkIf (cfg.enable && battery.enable) {
    services.unison-cloud.consul.address = address;

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
              IPAddressDeny = "any";
              IPAddressAllow = "localhost";
              ExecStartPre = writeTokens;
              ExecStart = "${lib.getExe battery.package} agent -config-file ${configFile} -config-file %t/unison-cloud-consul/tokens.json";
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
          requiredBy = clients;
          before = clients;
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
    };
  };
}
