{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  proxyUser = "unison-cloud-outbound-proxy";
  resolverUser = "unison-cloud-resolver";
  resolverDir = "${cfg.stateDir}/resolver";
  bundledResolver = cfg.egress.nameservers == [];
  nimbusUnits = lib.optionals cfg.nimbus.enable (map (node: node.unit) cfg.internal.nimbusNodes);

  # Adapted from upstream's cloud-api/outbound-proxy/squid.conf, without its allowlist of
  # internal hosts: nimbus's own traffic never goes through this proxy (nimbus patch 0002).
  squidConfig = pkgs.writeText "unison-cloud-squid.conf" ''
    http_port 127.0.0.1:${toString cfg.internal.outboundProxyPort}

    pid_filename none
    coredump_dir none
    netdb_filename none
    cache deny all
    cache_log /dev/null
    access_log syslog:daemon.info squid
    shutdown_lifetime 1 seconds

    # Names on the namespace's /etc/hosts, such as the S3 hostnames, must
    # not resolve for hosted code.
    hosts_file none
    dns_nameservers ${
      if bundledResolver
      then "127.0.0.1"
      else lib.concatStringsSep " " cfg.egress.nameservers
    }

    acl localnet_dst dst 0.0.0.0/8
    acl localnet_dst dst 10.0.0.0/8
    acl localnet_dst dst 100.64.0.0/10
    acl localnet_dst dst 169.254.0.0/16
    acl localnet_dst dst 172.16.0.0/12
    acl localnet_dst dst 192.168.0.0/16
    acl localnet_dst dst fc00::/7
    acl localnet_dst dst fe80::/10

    acl SSL_ports port 443
    acl Safe_ports port 80
    acl Safe_ports port 21
    acl Safe_ports port 443
    acl Safe_ports port 70
    acl Safe_ports port 210
    acl Safe_ports port 1025-65535
    acl Safe_ports port 280
    acl Safe_ports port 488
    acl Safe_ports port 591
    acl Safe_ports port 777
    acl CONNECT method CONNECT

    http_access deny !Safe_ports
    http_access deny CONNECT !SSL_ports
    http_access deny manager
    # Squid checks the resolved address, so a public name pointing at loopback or a
    # private range is refused too.
    http_access deny to_localhost
    http_access deny to_linklocal
    http_access deny localnet_dst
    http_access allow all

    http_upgrade_request_protocols websocket allow all
    http_upgrade_request_protocols WebSocket allow all
  '';

  unboundConfig = pkgs.writeText "unison-cloud-unbound.conf" ''
    server:
      interface: 127.0.0.1
      port: 53
      access-control: 127.0.0.0/8 allow
      do-daemonize: no
      username: ""
      chroot: ""
      pidfile: ""
      directory: "${resolverDir}"
      use-syslog: no
      logfile: ""
      auto-trust-anchor-file: "${resolverDir}/root.key"
  '';
in {
  options.services.unison-cloud = {
    egress.nameservers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["9.9.9.9" "149.112.112.112"];
      description = ''
        IP addresses of the resolvers the outbound proxy resolves hosted code's
        destinations with. Empty runs a recursive Unbound inside the namespace, which asks
        the root servers directly, so hosted code can't learn names that only exist on
        your network.
      '';
    };

    internal.outboundProxyPort = lib.mkOption {
      type = lib.types.port;
      internal = true;
      readOnly = true;
      default = 24155;
      description = "Port of the outbound proxy hosted code's requests go through, on the namespace loopback.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.unison-cloud.nimbus.outboundProxy = lib.mkDefault {
      host = "127.0.0.1";
      port = cfg.internal.outboundProxyPort;
    };
    # Only the proxy, and the resolver it asks, may send traffic out of the namespace.
    services.unison-cloud.internal.egressUsers = [proxyUser] ++ lib.optional bundledResolver resolverUser;

    users.users =
      {
        ${proxyUser} = {
          isSystemUser = true;
          group = proxyUser;
        };
      }
      // lib.optionalAttrs bundledResolver {
        ${resolverUser} = {
          isSystemUser = true;
          group = resolverUser;
        };
      };
    users.groups =
      {${proxyUser} = {};}
      // lib.optionalAttrs bundledResolver {${resolverUser} = {};};

    systemd.tmpfiles.settings.unison-cloud-resolver = lib.mkIf bundledResolver {
      ${resolverDir}.d = {
        user = resolverUser;
        group = resolverUser;
        mode = "0700";
      };
    };

    systemd.services.unison-cloud-outbound-proxy = lib.mkMerge [
      cfg.internal.inNamespace
      {
        description = "Unison Cloud outbound proxy for hosted code (Squid)";
        wantedBy = ["multi-user.target"];
        requiredBy = nimbusUnits;
        before = nimbusUnits;
        requires = lib.optional bundledResolver "unison-cloud-resolver.service";
        after = lib.optional bundledResolver "unison-cloud-resolver.service";
        serviceConfig = {
          User = proxyUser;
          Group = proxyUser;
          ExecStartPre = "${lib.getExe' pkgs.squid "squid"} -k parse -f ${squidConfig}";
          ExecStart = "${lib.getExe' pkgs.squid "squid"} -N -d 1 -f ${squidConfig}";
          ExecReload = "${lib.getExe' pkgs.coreutils "kill"} -HUP $MAINPID";
          Restart = "on-failure";
        };
      }
    ];

    systemd.services.unison-cloud-resolver = lib.mkIf bundledResolver (lib.mkMerge [
      cfg.internal.inNamespace
      {
        description = "Unison Cloud recursive resolver for the outbound proxy (Unbound)";
        serviceConfig = {
          User = resolverUser;
          Group = resolverUser;
          AmbientCapabilities = ["CAP_NET_BIND_SERVICE"];
          CapabilityBoundingSet = ["CAP_NET_BIND_SERVICE"];
          # Unbound keeps the root trust anchor up to date itself once it has a copy.
          ExecStartPre = pkgs.writeShellScript "unison-cloud-resolver-anchor" ''
            if [ ! -e ${resolverDir}/root.key ]; then
              install -m 0600 ${pkgs.dns-root-data}/root.key ${resolverDir}/root.key
            fi
          '';
          ExecStart = "${lib.getExe' pkgs.unbound "unbound"} -d -c ${unboundConfig}";
          ExecReload = "${lib.getExe' pkgs.coreutils "kill"} -HUP $MAINPID";
          Restart = "on-failure";
        };
      }
    ]);
  };
}
