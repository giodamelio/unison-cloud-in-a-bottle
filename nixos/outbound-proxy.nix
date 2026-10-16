{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  proxyUser = "unison-cloud-outbound-proxy";
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

    # Names in the host's /etc/hosts, such as the S3 hostnames, must not resolve for
    # hosted code. Everything else resolves through the host's resolver.
    hosts_file none

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
in {
  options.services.unison-cloud.internal.outboundProxyPort = lib.mkOption {
    type = lib.types.port;
    internal = true;
    readOnly = true;
    default = 24155;
    description = "Port of the outbound proxy hosted code's requests go through, on loopback.";
  };

  config = lib.mkIf cfg.enable {
    services.unison-cloud.nimbus.outboundProxy = lib.mkDefault {
      host = "127.0.0.1";
      port = cfg.internal.outboundProxyPort;
    };

    users.users.${proxyUser} = {
      isSystemUser = true;
      group = proxyUser;
    };
    users.groups.${proxyUser} = {};

    systemd.services.unison-cloud-outbound-proxy = lib.mkMerge [
      cfg.internal.sandbox
      {
        description = "Unison Cloud outbound proxy for hosted code (Squid)";
        wantedBy = ["multi-user.target"];
        requiredBy = nimbusUnits;
        before = nimbusUnits;
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
  };
}
