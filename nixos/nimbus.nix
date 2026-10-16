{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  user = "unison-cloud-nimbus";
  curl = lib.getExe pkgs.curl;

  pg = cfg.internal.postgres;
  ext = cfg.database.external.nimbus;
  # nimbus's sandbox forbids unix sockets, so it logs in over TCP with a password even
  # where every other service uses peer authentication.
  db = {
    inherit (cfg.internal.postgresTcp) host port;
    user =
      if pg.external
      then ext.user
      else user;
    database =
      if pg.external
      then ext.database
      else "unison_cloud_nimbus";
    table = "nimbus_kv";
  };
  dbPassword =
    if pg.external
    then {LoadCredential = ["nimbus-db-password:${ext.passwordFile}"];}
    else cfg.internal.loadSecrets ["nimbus-db-password"];

  createTable = pkgs.writeText "unison-cloud-nimbus-storage.sql" ''
    CREATE TABLE IF NOT EXISTS ${db.table} (
      k  bytea  NOT NULL,
      ns text   NOT NULL,
      v  bytea  NOT NULL,
      t  bigint NOT NULL,
      fk bytea,
      PRIMARY KEY (k, ns)
    );
  '';

  # Fixed so a node keeps its identity across restarts; nimbus picks a random one otherwise.
  nodeId = name: let
    h = builtins.hashString "sha256" "unison-cloud-nimbus-${name}";
    s = builtins.substring;
  in "${s 0 8 h}-${s 8 4 h}-4${s 13 3 h}-8${s 17 3 h}-${s 20 12 h}";

  # nimbus binds every listener on all addresses and ignores `host`, so nodes sharing a
  # host each get their own block of ports. The public-daemon node comes first, so
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
    base = cfg.nimbus.basePort + 10 * slot;
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
    pkgs.writeText "unison-cloud-nimbus-${node.name}.json" (builtins.toJSON ({
        host = cfg.advertiseAddress;
        inherit (node) nodeId;
        nodeType = node.type;
        bindPorts = node.ports;
        clusterMap = {};
        tcpConfig.type = "everybody";
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
        dynamo =
          {type = "postgres";}
          // db;
        vault = {
          host = cfg.nimbus.cloudApiHost;
          port = cfg.cloudApi.secretsPort;
          scheme = "http";
        };
        cloudApiInstances = [{uri = "http://${cfg.nimbus.cloudApiHost}:${toString cfg.cloudApi.port}";}];
        # The client's `Cloud.logs` gets a token from cloud-api and then asks nimbus, which
        # queries Loki itself; the labels are the ones the log shipper sets.
        logs.provider = {
          type = "loki";
          uri = cfg.logs.lokiUrl;
          labels = {
            job = "nomad_allocs";
            namespace = "user";
            task_name = "nimbus";
          };
        };
        blockedUsers = map (lib.replaceStrings ["-"] [""]) cfg.nimbus.blockedUsers;
      }
      # nimbus reads the proxy as optional, so leaving the key out sends hosted code's
      # requests straight out.
      // lib.optionalAttrs (cfg.nimbus.outboundProxy != null) {
        inherit (cfg.nimbus) outboundProxy;
      }));

  # Secrets stay out of the store: the generated config is merged with them at start.
  renderConfig = node:
    pkgs.writeShellScript "unison-cloud-nimbus-${node.name}-config" ''
      umask 077
      creds=$CREDENTIALS_DIRECTORY
      ${lib.getExe pkgs.jq} \
        --rawfile s3Id "$creds/s3-access-key-id" --rawfile s3Secret "$creds/s3-secret-access-key" \
        --rawfile dbPassword "$creds/nimbus-db-password" \
        --rawfile token "$creds/cluster-token" \
        'def trim: rtrimstr("\n");
         def s3: {awsConfig: {credentials: {accessKey: ($s3Id | trim), secretKey: ($s3Secret | trim)}}};
         . * {
           blobFetcher: s3,
           userBlobFetcher: s3,
           dynamo: {password: ($dbPassword | trim)},
           vault: {token: ($token | trim)},
           cloudApiToken: ($token | trim)
         }' ${nodeConfig node} > "$RUNTIME_DIRECTORY/config.json.tmp"
      mv "$RUNTIME_DIRECTORY/config.json.tmp" "$RUNTIME_DIRECTORY/config.json"
    '';

  gossip = node: path: "http://127.0.0.1:${toString node.ports.gossipHttp}${path}";

  nodeService = node:
    lib.mkMerge [
      cfg.internal.sandbox
      {
        description = "Unison Cloud nimbus node ${node.name}";
        wantedBy = ["multi-user.target"];
        requires =
          ["unison-cloud-nimbus-storage.service"]
          ++ lib.optional cfg.cloudApi.enable "unison-cloud-api.service"
          ++ lib.optional (cfg.internal.s3.unit != null) cfg.internal.s3.unit;
        after =
          ["unison-cloud-nimbus-storage.service"]
          ++ lib.optional cfg.cloudApi.enable "unison-cloud-api.service"
          ++ lib.optional (cfg.internal.s3.unit != null) cfg.internal.s3.unit;
        environment = {
          HOME = "%t/unison-cloud-nimbus-${node.name}";
          NIMBUS_CONFIG_FILE = "%t/unison-cloud-nimbus-${node.name}/config.json";
          GHCRTS = "-N -C0.003 -qb -qn1";
        };
        # Hosted code runs in this process. It reaches the network like any other process
        # on the host, but the sandbox hides /run and /var and the process can't open a
        # unix socket at all, so the host's sockets and state stay out of its reach.
        serviceConfig = lib.mkMerge [
          cfg.internal.hostIsolation
          (cfg.internal.loadSecrets [
            "s3-access-key-id"
            "s3-secret-access-key"
            "cluster-token"
          ])
          dbPassword
          {
            User = user;
            Group = user;
            RuntimeDirectory = "unison-cloud-nimbus-${node.name}";
            BindPaths = ["%t/unison-cloud-nimbus-${node.name}"];
            RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
            SystemCallFilter = ["@system-service"];
            RemoveIPC = true;
            KeyringMode = "private";
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

      cloudApiHost = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = ''
          Address the nodes reach cloud-api's HTTP port and secrets listener at. Set it to
          the cloud-api host's address when this host runs `cloudApi.enable = false`.
        '';
      };

      outboundProxy = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            host = lib.mkOption {type = lib.types.str;};
            port = lib.mkOption {type = lib.types.port;};
          };
        });
        default = null;
        example = {
          host = "127.0.0.1";
          port = 3128;
        };
        description = ''
          HTTP proxy hosted code's outbound requests go through. With `null`, hosted code
          connects directly, to anything this host can reach. nimbus's own storage traffic
          never uses the proxy (nimbus patch 0002).
        '';
      };

      basePort = lib.mkOption {
        type = lib.types.port;
        default = 24200;
        description = ''
          First port of the nodes' port blocks. nimbus listens on every address, so node
          `k` (the public-daemon node is 0) takes the four ports from `basePort + 10 * k`.
        '';
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
    assertions = [
      {
        assertion = cfg.cloudApi.enable || !(lib.hasPrefix "127." cfg.nimbus.cloudApiHost || cfg.nimbus.cloudApiHost == "localhost" || cfg.nimbus.cloudApiHost == "::1");
        message = "services.unison-cloud: with cloudApi.enable = false, set nimbus.cloudApiHost to the address of the host that runs cloud-api.";
      }
    ];

    users.users.${user} = {
      isSystemUser = true;
      group = user;
    };
    users.groups.${user} = {};

    services.unison-cloud.internal.postgresRoles.${user}.passwordCredential = "nimbus-db-password";
    services.unison-cloud.internal.postgresDatabases.${db.database}.owner = user;

    # cloud-api registers the nodes itself (`<prefix>-nimbus-http`) when they join; this
    # is only for its TCP client path, which looks nodes up as `<prefix>-nimbus-client`.
    services.unison-cloud.internal.consulServices =
      map (node: {
        ID = "${cfg.consul.prefix}-nimbus-client-${node.name}";
        Name = "${cfg.consul.prefix}-nimbus-client";
        Address = cfg.advertiseAddress;
        Port = node.ports.client;
        Checks = [
          {
            TCP = "127.0.0.1:${toString node.ports.client}";
            Interval = "10s";
          }
        ];
      })
      nodes;

    systemd.services =
      {
        # Creates the table as nimbus's own role, over the same path nimbus uses, so the
        # role owns it in every database mode and a broken path fails here, not in a node.
        unison-cloud-nimbus-storage = lib.mkMerge [
          cfg.internal.sandbox
          {
            description = "Create the Unison Cloud nimbus storage table";
            requires = ["unison-cloud-postgresql-setup.service" "unison-cloud-secrets.service"];
            after = ["unison-cloud-postgresql-setup.service" "unison-cloud-secrets.service"];
            environment = {
              PGHOST = db.host;
              PGPORT = toString db.port;
              PGDATABASE = db.database;
              PGUSER = db.user;
            };
            serviceConfig = lib.mkMerge [
              dbPassword
              {
                Type = "oneshot";
                RemainAfterExit = true;
                User = user;
                Group = user;
                ExecStart = pkgs.writeShellScript "unison-cloud-nimbus-storage" ''
                  PGPASSWORD=$(< "$CREDENTIALS_DIRECTORY/nimbus-db-password")
                  export PGPASSWORD
                  ${cfg.database.package}/bin/psql -X -q -v ON_ERROR_STOP=1 -f ${createTable}
                '';
              }
            ];
          }
        ];
      }
      // lib.listToAttrs (map (node: lib.nameValuePair "unison-cloud-nimbus-${node.name}" (nodeService node)) nodes);
  };
}
