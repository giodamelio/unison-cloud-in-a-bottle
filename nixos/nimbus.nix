{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  user = "unison-cloud-nimbus";
  secrets = "${cfg.stateDir}/secrets";
  caBundleDir = "/run/unison-cloud-nimbus";
  curl = lib.getExe pkgs.curl;

  # Fixed so a node keeps its identity across restarts; nimbus picks a random one otherwise.
  nodeId = name: let
    h = builtins.hashString "sha256" "unison-cloud-nimbus-${name}";
    s = builtins.substring;
  in "${s 0 8 h}-${s 8 4 h}-4${s 13 3 h}-8${s 17 3 h}-${s 20 12 h}";

  # nimbus binds every listener on all addresses and ignores `host`, so nodes sharing the
  # namespace each get their own block of ports. The public-daemon node comes first, so
  # changing the number of interactive nodes never moves it.
  groups = [
    {
      type = "public-daemon";
      count = 1;
    }
    {
      type = "interactive";
      count = cfg.nimbus.nodes.interactive;
    }
  ];
  nodes = lib.imap0 (slot: node: let
    base = 17010 + 10 * slot;
  in
    node
    // {
      name = "${node.type}-${toString node.index}";
      unit = "unison-cloud-nimbus-${node.type}-${toString node.index}.service";
      nodeId = nodeId "${node.type}-${toString node.index}";
      ports = {
        client = base;
        publicHttp = base + 1;
        gossipHttp = base + 2;
        gossipTcp = base + 3;
      };
    }) (lib.concatMap (group:
    lib.genList (index: {
      inherit (group) type count;
      inherit index;
    })
    group.count)
  groups);

  awsConfig = {
    hostName = cfg.internal.s3.host;
    inherit (cfg.internal.s3) port region https;
    service = "s3";
  };

  nodeConfig = node:
    pkgs.writeText "unison-cloud-nimbus-${node.name}.json" (builtins.toJSON {
      host = "127.0.0.1";
      inherit (node) nodeId;
      nodeType = node.type;
      bindPorts = node.ports;
      clusterMap = {};
      tcpConfig.type = "everybody";
      outboundProxy = {
        host = "127.0.0.1";
        port = cfg.internal.outboundProxyPort;
      };
      cors = {
        origins.${cfg.internal.publicUrl.ui} = false;
        allowHeaders = ["Authorization"];
        exposeHeaders = ["Content-Encoding"];
        varyOrigin = true;
      };
      shards = {
        shardCount = 1;
        logicalLocationCount = node.count;
        allocationIndex = node.index;
      };
      blobFetcher = {
        bucket = cfg.s3.buckets.services;
        inherit awsConfig;
      };
      userBlobFetcher = {
        bucket = cfg.s3.buckets.userBlobs;
        inherit awsConfig;
      };
      dynamo = {
        type = "local-https";
        host = cfg.internal.extenddbHost;
        port = cfg.extenddb.port;
        table = cfg.extenddb.tableName;
      };
      vault = {
        host = "127.0.0.1";
        port = cfg.internal.secretsPort;
        scheme = "http";
      };
      cloudApiInstances = [{uri = "http://127.0.0.1:${toString cfg.internal.cloudApiPort}";}];
      # The client's `Cloud.logs` gets a token from cloud-api and then asks nimbus, which
      # queries Loki itself; the labels are the ones the log shipper sets.
      logs.provider = {
        type = "loki";
        uri = "http://127.0.0.1:${toString cfg.internal.lokiPort}";
        labels = {
          job = "nomad_allocs";
          namespace = "user";
          task_name = "nimbus";
        };
      };
      blockedUsers = map (lib.replaceStrings ["-"] [""]) cfg.nimbus.blockedUsers;
    });

  # Secrets stay out of the store: the generated config is merged with them at start.
  renderConfig = node:
    pkgs.writeShellScript "unison-cloud-nimbus-${node.name}-config" ''
      umask 077
      creds=$CREDENTIALS_DIRECTORY
      ${lib.getExe pkgs.jq} \
        --rawfile s3Id "$creds/s3-access-key-id" --rawfile s3Secret "$creds/s3-secret-access-key" \
        --rawfile dynamoId "$creds/extenddb-access-key-id" --rawfile dynamoSecret "$creds/extenddb-secret-access-key" \
        --rawfile token "$creds/cluster-token" \
        'def trim: rtrimstr("\n");
         def s3: {awsConfig: {credentials: {accessKey: ($s3Id | trim), secretKey: ($s3Secret | trim)}}};
         . * {
           blobFetcher: s3,
           userBlobFetcher: s3,
           dynamo: {credentials: {accessKey: ($dynamoId | trim), secretKey: ($dynamoSecret | trim)}},
           vault: {token: ($token | trim)},
           cloudApiToken: ($token | trim)
         }' ${nodeConfig node} > "$RUNTIME_DIRECTORY/config.json.tmp"
      mv "$RUNTIME_DIRECTORY/config.json.tmp" "$RUNTIME_DIRECTORY/config.json"
    '';

  gossip = node: path: "http://127.0.0.1:${toString node.ports.gossipHttp}${path}";

  nodeService = node:
    lib.mkMerge [
      cfg.internal.inNamespace
      {
        description = "Unison Cloud nimbus node ${node.name}";
        wantedBy = ["multi-user.target"];
        requires =
          [
            "unison-cloud-nimbus-ca.service"
            "unison-cloud-extenddb-setup.service"
            "unison-cloud-outbound-proxy.service"
            "unison-cloud-api.service"
          ]
          ++ lib.optional (cfg.internal.s3.unit != null) cfg.internal.s3.unit;
        after =
          [
            "unison-cloud-nimbus-ca.service"
            "unison-cloud-extenddb-setup.service"
            "unison-cloud-outbound-proxy.service"
            "unison-cloud-api.service"
          ]
          ++ lib.optional (cfg.internal.s3.unit != null) cfg.internal.s3.unit;
        environment = {
          HOME = "%t/unison-cloud-nimbus-${node.name}";
          NIMBUS_CONFIG_FILE = "%t/unison-cloud-nimbus-${node.name}/config.json";
          GHCRTS = "-N -C0.003 -qb -qn1";
        };
        # Hosted code runs in this process. The namespace keeps its TCP and UDP to what the
        # firewall allows, but unix sockets and files are shared with the host, so the
        # sandbox hides /run and /var and the process can't open a unix socket at all.
        serviceConfig = lib.mkMerge [
          cfg.internal.hostIsolation
          cfg.internal.s3Hosts
          (cfg.internal.loadSecrets [
            "s3-access-key-id"
            "s3-secret-access-key"
            "extenddb-access-key-id"
            "extenddb-secret-access-key"
            "cluster-token"
          ])
          {
            User = user;
            Group = user;
            RuntimeDirectory = "unison-cloud-nimbus-${node.name}";
            BindPaths = ["%t/unison-cloud-nimbus-${node.name}"];
            RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
            SystemCallFilter = ["@system-service"];
            RemoveIPC = true;
            KeyringMode = "private";
            # The Unison runtime only reads the system bundle, and ExtendDB's certificate is
            # issued by the module's own CA.
            BindReadOnlyPaths = ["${caBundleDir}/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt"];
            ExecStartPre = renderConfig node;
            ExecStart = lib.getExe cfg.nimbus.package;
            # /ready answers 204 once the node has joined cloud-api.
            ExecStartPost = pkgs.writeShellScript "unison-cloud-nimbus-${node.name}-ready" ''
              until ${curl} -sf -o /dev/null ${gossip node "/ready"}; do sleep 1; done
            '';
            TimeoutStartSec = 300;
            # Lets in-flight work drain, as upstream's nimbus.sh does on SIGTERM; systemd
            # would otherwise kill ucm mid-request.
            ExecStop = pkgs.writeShellScript "unison-cloud-nimbus-${node.name}-stop" ''
              ${curl} -sS --fail-with-body -X POST ${gossip node "/internal/shutdown"}
              ${lib.getExe' pkgs.coreutils "tail"} --pid="$MAINPID" -f /dev/null
            '';
            ExecReload = [
              (renderConfig node)
              "${curl} -sS --fail-with-body -X POST ${gossip node "/internal/reload-config"}"
            ];
            Restart = "on-failure";
          }
        ];
      }
    ];
in {
  options.services.unison-cloud = {
    nimbus = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Run the nimbus nodes. Without them cloud-api still serves logins and the API, but
          nothing can be deployed. Each node needs roughly 700 MiB of memory while idle.
        '';
      };

      nodes.interactive = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2;
        description = ''
          Number of interactive nimbus nodes, which serve deployed services and accept
          deploys. The module always adds exactly one public-daemon node: every such node
          runs every daemon, so a second one would run each daemon twice.
        '';
      };

      blockedUsers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["1f13c72e-b554-4622-9d8e-fc5a603700a2"];
        description = "IDs of users nimbus refuses to run code for.";
      };
    };

    internal.nimbusNodes = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      internal = true;
      readOnly = true;
      default = nodes;
      description = "Every nimbus node with its type, index, unit, node ID and ports.";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.nimbus.enable) {
    users.users.${user} = {
      isSystemUser = true;
      group = user;
    };
    users.groups.${user} = {};

    # Hosted code runs as this user too, so it gets only what nimbus itself connects to,
    # and never egress: an external S3 is behind a bridge on the S3 port.
    # nimbus never reads Consul: cloud-api registers the nodes.
    services.unison-cloud.internal.loopbackRestrictedUsers.${user} =
      [
        cfg.internal.outboundProxyPort
        cfg.internal.cloudApiPort
        cfg.internal.secretsPort
        cfg.internal.lokiPort
        cfg.extenddb.port
        cfg.internal.s3Port
      ]
      ++ lib.concatMap (node: lib.attrValues node.ports) nodes;

    # cloud-api registers the nodes itself (`byoc-nimbus-http`) when they join; this is
    # only for its TCP client path, which looks nodes up as `nimbus-client`.
    services.unison-cloud.internal.consulServices =
      map (node: {
        id = "nimbus-client-${node.name}";
        name = "nimbus-client";
        address = "127.0.0.1";
        port = node.ports.client;
        checks = [
          {
            tcp = "127.0.0.1:${toString node.ports.client}";
            interval = "10s";
          }
        ];
      })
      nodes;

    services.unison-cloud.internal.ingressSockets =
      lib.listToAttrs (map (node: lib.nameValuePair "nimbus-${node.name}" node.ports.publicHttp)
        (lib.filter (node: node.type == "interactive") nodes));

    # A bind mount's source must exist before the unit starts, so the bundle is built by
    # its own unit rather than in each node's ExecStartPre.
    systemd.services =
      {
        unison-cloud-nimbus-ca = {
          description = "Build the CA bundle the Unison Cloud nimbus nodes trust";
          requires = ["unison-cloud-secrets.service"];
          after = ["unison-cloud-secrets.service"];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            RuntimeDirectory = baseNameOf caBundleDir;
            RuntimeDirectoryMode = "0755";
            ExecStart = pkgs.writeShellScript "unison-cloud-nimbus-ca" ''
              cat /etc/ssl/certs/ca-certificates.crt ${secrets}/ca.crt > ${caBundleDir}/ca-bundle.crt.tmp
              chmod 0644 ${caBundleDir}/ca-bundle.crt.tmp
              mv ${caBundleDir}/ca-bundle.crt.tmp ${caBundleDir}/ca-bundle.crt
            '';
          };
        };
      }
      // lib.listToAttrs (map (node: lib.nameValuePair "unison-cloud-nimbus-${node.name}" (nodeService node)) nodes);
  };
}
