{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
  ns = cfg.network.namespace;
  ip = lib.getExe' pkgs.iproute2 "ip";
  nft = lib.getExe pkgs.nftables;

  ipv4Cidr = "([0-9]{1,3}\\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?";

  subnetParts = lib.splitString "/" cfg.network.subnet;
  prefixLength = lib.toInt (lib.elemAt subnetParts 1);
  subnetBase = lib.foldl (acc: octet: acc * 256 + lib.toInt octet) 0 (lib.splitString "." (lib.head subnetParts));
  showIPv4 = n: lib.concatMapStringsSep "." (shift: toString (lib.mod (n / shift) 256)) [16777216 65536 256 1];
  hostAddress = showIPv4 (subnetBase + 1);
  namespaceAddress = showIPv4 (subnetBase + 2);

  # Interface names are capped at 15 characters, so they can't be derived from the namespace name.
  hostVeth = "ucloud-host";
  namespaceVeth = "ucloud-ns";

  blockedIPv4 = [
    "0.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "224.0.0.0/4"
    "240.0.0.0/4"
  ];
  blockedIPv6 = ["::/128" "::1/128" "fc00::/7" "fe80::/10" "ff00::/8"];

  allowRule = {
    address,
    port,
  }:
    "ip daddr ${address}"
    + lib.optionalString (port != null) " meta l4proto { tcp, udp } th dport ${toString port}"
    + " accept";
  allowedRules = lib.concatMapStringsSep "\n" allowRule cfg.egress.allowedDestinations;

  hostRules = ''
    chain from-namespace {
      ${allowedRules}
      ${lib.optionalString (cfg.egress.nameservers != []) "ip daddr { ${lib.concatStringsSep ", " cfg.egress.nameservers} } meta l4proto { tcp, udp } th dport 53 accept"}
      ${lib.optionalString cfg.egress.blockPrivateRanges ''
      ip daddr { ${lib.concatStringsSep ", " blockedIPv4} } drop
      ip6 daddr { ${lib.concatStringsSep ", " blockedIPv6} } drop
    ''}
    }

    chain input {
      type filter hook input priority filter; policy accept;
      iifname "${hostVeth}" ct state established,related accept
      iifname "${hostVeth}" jump from-namespace
      ${lib.optionalString cfg.egress.blockPrivateRanges ''iifname "${hostVeth}" drop''}
    }

    chain forward {
      type filter hook forward priority filter; policy accept;
      oifname "${hostVeth}" ct state established,related accept
      oifname "${hostVeth}" drop
      iifname "${hostVeth}" jump from-namespace
      ${lib.optionalString (cfg.network.uplinkInterface != null) ''iifname "${hostVeth}" oifname != "${cfg.network.uplinkInterface}" drop''}
    }

    chain postrouting {
      type nat hook postrouting priority srcnat; policy accept;
      iifname "${hostVeth}" oifname ${
      if cfg.network.uplinkInterface == null
      then ''!= "${hostVeth}"''
      else ''"${cfg.network.uplinkInterface}"''
    } masquerade
    }
  '';

  quoted = map (s: ''"${s}"'');
  loopbackRule = user: ports:
    lib.optionalString (ports != []) ''
      meta skuid "${user}" ip daddr 127.0.0.0/8 meta l4proto { tcp, udp } th dport { ${lib.concatMapStringsSep ", " toString ports} } accept
    ''
    + ''
      meta skuid "${user}" reject
    '';

  # Loaded inside the namespace, where a socket's owner is still visible. Deleting the
  # table in the same transaction makes the file safe to load again on reload.
  boundaryRules = pkgs.writeText "unison-cloud-boundary.nft" ''
    table inet unison-cloud-boundary
    delete table inet unison-cloud-boundary
    table inet unison-cloud-boundary {
      chain loopback {
        ${lib.concatStrings (lib.mapAttrsToList loopbackRule cfg.internal.loopbackRestrictedUsers)}
      }

      chain output {
        type filter hook output priority filter; policy accept;
        ct state established,related accept
        oifname "lo" jump loopback
        oifname "lo" accept
        ${allowedRules}
        ${lib.optionalString (cfg.internal.egressUsers != []) "meta skuid { ${lib.concatStringsSep ", " (quoted cfg.internal.egressUsers)} } accept"}
        reject
      }
    }
  '';
in {
  options.services.unison-cloud = {
    network = {
      subnet = lib.mkOption {
        type = lib.types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|30)";
        default = "10.88.0.0/30";
        description = ''
          IPv4 network of the veth pair between the host and the namespace. The host side
          takes its first address and the namespace side its second.
        '';
      };

      uplinkInterface = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "eth0";
        description = ''
          Interface the namespace's traffic is masqueraded out of. With it set, the
          namespace's traffic may leave through it only; `null` masquerades out of any
          interface the host routes it to.
        '';
      };
    };

    egress = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Give the namespace outbound internet through a veth pair and masquerading on the
          host. Needs `networking.nftables.enable`.

          This turns on IPv4 forwarding (`net.ipv4.conf.all.forwarding`) for the whole
          host, so without a forward filter the host routes between all its interfaces.
          Set `networking.firewall.filterForward = true`. The module adds its own
          forward rule for the namespace's veth, so egress keeps working with it on.
        '';
      };

      blockPrivateRanges = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Drop traffic from the namespace to private, CGN, link-local, loopback, multicast
          and IPv6 ULA ranges, and to every address of the host itself. With it off, the
          namespace reaches your network, and the host's ports that its firewall opens.
        '';
      };

      allowedDestinations = lib.mkOption {
        type = let
          destination = lib.types.submodule {
            options = {
              address = lib.mkOption {
                type = lib.types.strMatching ipv4Cidr;
                description = "IPv4 address or CIDR range.";
              };
              port = lib.mkOption {
                type = lib.types.nullOr lib.types.port;
                default = null;
                description = "TCP and UDP destination port; `null` allows every port.";
              };
            };
          };
        in
          lib.types.listOf (lib.types.coercedTo lib.types.str (address: {inherit address;}) destination);
        default = [];
        example = [
          "10.0.5.0/24"
          {
            address = "192.168.1.20";
            port = 5432;
          }
        ];
        description = ''
          Destinations exempt from `blockPrivateRanges`, such as an external database or
          S3: an IPv4 address or range as a string for every port, or
          `{ address; port; }` for one port. Every service in the namespace may connect to
          them directly through the veth, not only the outbound proxy, so hosted code can
          too; list only destinations that check credentials, and prefer a port.
        '';
      };
    };

    internal = {
      egressUsers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        internal = true;
        default = [];
        description = ''
          Users whose sockets may send traffic out of the namespace through the veth, to
          any destination the host's egress rules allow. Every other user is refused,
          except for `egress.allowedDestinations`. Each user must exist when the
          namespace's rules load.
        '';
      };

      loopbackRestrictedUsers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf lib.types.port);
        internal = true;
        default = {};
        example = {unison-cloud-nimbus = [3128 8500];};
        description = ''
          Users limited to these destination ports (TCP and UDP) on 127.0.0.0/8 inside
          the namespace. Their other connections over the namespace loopback, including to
          the namespace's own veth address, are rejected. Replies on connections they
          accepted are unaffected. Users not listed are unrestricted on loopback.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = lib.all (s: !lib.hasInfix ":" s) cfg.egress.nameservers;
          message = "services.unison-cloud: egress.nameservers must be IPv4 addresses; the namespace has no IPv6 route out.";
        }
      ];

      systemd.services.unison-cloud-netns-firewall = {
        description = "Unison Cloud per-user firewall inside the network namespace";
        wantedBy = ["multi-user.target"];
        bindsTo = ["unison-cloud-netns.service"];
        after = ["unison-cloud-netns.service"];
        reloadIfChanged = true;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          NetworkNamespacePath = "/run/netns/${ns}";
          ExecStart = "${nft} -f ${boundaryRules}";
          ExecReload = "${nft} -f ${boundaryRules}";
        };
      };
    }

    (lib.mkIf cfg.egress.enable {
      assertions = [
        {
          assertion = config.networking.nftables.enable;
          message = "services.unison-cloud: egress needs networking.nftables.enable = true; its NAT and filter rules are nftables tables.";
        }
        {
          assertion = lib.mod subnetBase (lib.foldl (acc: _: acc * 2) 1 (lib.range 1 (32 - prefixLength))) == 0;
          message = "services.unison-cloud: network.subnet must be a network address, such as 10.88.0.0/30.";
        }
      ];

      boot.kernel.sysctl."net.ipv4.conf.all.forwarding" = true;

      networking.nftables.tables.unison-cloud-egress = {
        family = "inet";
        content = hostRules;
      };

      # The namespace's own rules decide what may leave; this keeps the host's forward
      # policy from dropping it when the host filters forwarded traffic.
      networking.firewall.extraForwardRules = ''iifname "${hostVeth}" accept'';
      networking.dhcpcd.denyInterfaces = [hostVeth];

      systemd.services.unison-cloud-netns.serviceConfig = {
        # Left behind if the namespace outlived its unit because a process still held it.
        ExecStartPre = ["-${ip} link delete ${hostVeth}"];
        ExecStart = lib.mkAfter [
          "${ip} link add ${hostVeth} type veth peer name ${namespaceVeth} netns ${ns}"
          "${ip} addr add ${hostAddress}/${toString prefixLength} dev ${hostVeth}"
          "${ip} link set ${hostVeth} up"
          "${ip} -n ${ns} addr add ${namespaceAddress}/${toString prefixLength} dev ${namespaceVeth}"
          "${ip} -n ${ns} link set ${namespaceVeth} up"
          "${ip} -n ${ns} route add default via ${hostAddress}"
        ];
      };
    })
  ]);
}
