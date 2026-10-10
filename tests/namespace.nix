self: let
  # The test VLAN is 192.168.1.0/24, which the egress rules treat as private. A second
  # network in TEST-NET-3 stands in for the public internet, and a third private one holds
  # the allowlisted destination.
  public = {
    internet = "203.0.113.2";
    machine = "203.0.113.1";
  };
  allowlisted = {
    internet = "10.20.0.2";
    machine = "10.20.0.1";
  };

  extraAddresses = node: [
    {
      address = public.${node};
      prefixLength = 24;
    }
    {
      address = allowlisted.${node};
      prefixLength = 24;
    }
  ];
in {
  name = "unison-cloud-namespace";

  nodes.internet = {
    lib,
    pkgs,
    ...
  }: {
    networking.interfaces.eth1.ipv4 = {
      addresses = extraAddresses "internet";
      # Lets the probe from outside actually aim at the namespace instead of failing to route.
      routes = [
        {
          address = "10.88.0.0";
          prefixLength = 30;
          via = public.machine;
        }
      ];
    };
    networking.firewall.allowedTCPPorts = [53 80];

    systemd.services = lib.genAttrs ["http-80" "http-53"] (name: {
      wantedBy = ["multi-user.target"];
      serviceConfig.ExecStart = "${lib.getExe pkgs.python3} -m http.server ${lib.removePrefix "http-" name} --directory ${pkgs.writeTextDir "index.html" "hello from the internet\n"}";
    });
  };

  nodes.machine = {
    nodes,
    lib,
    pkgs,
    ...
  }: {
    imports = [self.nixosModules.default];

    networking.nftables.enable = true;
    networking.interfaces.eth1.ipv4.addresses = extraAddresses "machine";
    networking.firewall.allowedTCPPorts = [9200];

    services.unison-cloud = {
      enable = true;
      domains = {
        api = "cloud.test";
        apps = "apps.test";
        ui = "ui.test";
      };
      egress = {
        allowedDestinations = [
          {
            address = allowlisted.internet;
            port = 80;
          }
        ];
        nameservers = [nodes.internet.networking.primaryIPAddress];
      };
      internal = {
        egressUsers = ["fakesquid"];
        loopbackRestrictedUsers.fakenimbus = [9001 9002];
      };
    };

    users.users = lib.genAttrs ["fakesquid" "fakenimbus"] (name: {
      isSystemUser = true;
      group = name;
    });
    users.groups = lib.genAttrs ["fakesquid" "fakenimbus"] (_: {});

    environment.systemPackages = [pkgs.curl pkgs.python3];

    virtualisation.memorySize = 3072;
  };

  testScript = {nodes, ...}: ''
    internet_vlan = "${nodes.internet.networking.primaryIPAddress}"
    machine_vlan = "${nodes.machine.networking.primaryIPAddress}"

    def connect(user, host, port):
        return (
            f"ip netns exec unison-cloud sudo -u {user} "
            f"timeout 5 bash -c 'exec 3<>/dev/tcp/{host}/{port}'"
        )

    def listen(unit, address, port, namespace=True):
        props = "-p NetworkNamespacePath=/run/netns/unison-cloud" if namespace else ""
        machine.succeed(
            f"systemd-run --unit {unit} {props} "
            f"$(command -v python3) -m http.server {port} --bind {address} --directory /etc"
        )

    start_all()
    internet.wait_for_unit("http-80.service")
    internet.wait_for_unit("http-53.service")
    machine.wait_for_unit("unison-cloud-netns-firewall.service")
    machine.wait_for_unit("unison-cloud-consul.service")
    machine.wait_for_unit("redis-unison-cloud.service")

    listen("ns-allowed", "127.0.0.1", 9001)
    listen("ns-any", "0.0.0.0", 9100)
    listen("host-probe", "0.0.0.0", 9200, namespace=False)
    machine.wait_for_open_port(9200)
    machine.wait_until_succeeds("ip netns exec unison-cloud curl -sf http://127.0.0.1:9001/hostname")
    machine.wait_until_succeeds("ip netns exec unison-cloud curl -sf http://127.0.0.1:9100/hostname")

    with subtest("the egress user reaches the internet through NAT"):
        out = machine.succeed(
            "ip netns exec unison-cloud sudo -u fakesquid "
            "curl -sf --max-time 5 http://${public.internet}/"
        )
        assert out == "hello from the internet\n", out

    with subtest("users outside the egress list can't leave the namespace"):
        for user in ["nobody", "fakenimbus", "root"]:
            machine.fail(connect(user, "${public.internet}", 80))

    with subtest("nobody in the namespace reaches the host"):
        internet.succeed(f"curl -sf --max-time 5 http://{machine_vlan}:9200/hostname")
        for address in ["10.88.0.1", machine_vlan, "${public.machine}", "${allowlisted.machine}"]:
            machine.fail(connect("fakesquid", address, 9200))
            machine.fail(connect("root", address, 9200))

    with subtest("private ranges are blocked except allowlisted destinations and nameservers"):
        machine.fail(connect("fakesquid", internet_vlan, 80))
        machine.succeed(connect("fakesquid", internet_vlan, 53))
        machine.fail(connect("nobody", internet_vlan, 53))
        machine.succeed(connect("fakesquid", "${allowlisted.internet}", 80))
        machine.succeed(connect("nobody", "${allowlisted.internet}", 80))
        machine.fail(connect("fakesquid", "${allowlisted.internet}", 53))

    with subtest("a loopback-restricted user reaches only its ports"):
        machine.succeed(connect("fakenimbus", "127.0.0.1", 9001))
        machine.succeed(
            "ip netns exec unison-cloud sudo -u fakenimbus "
            "curl -sf --max-time 5 http://127.0.0.1:9001/hostname"
        )
        for port in [6379, 8500, 9100]:
            machine.fail(connect("fakenimbus", "127.0.0.1", port))
        machine.fail(connect("fakenimbus", "10.88.0.2", 9100))

    with subtest("unrestricted users keep the whole loopback"):
        machine.wait_until_succeeds(connect("root", "127.0.0.1", 8500))
        machine.succeed(connect("nobody", "127.0.0.1", 6379))
        machine.succeed(connect("nobody", "10.88.0.2", 9100))

    with subtest("nothing outside reaches a namespace port"):
        machine.succeed("curl -sf --max-time 5 http://10.88.0.2:9100/hostname")
        internet.fail("curl -sf --max-time 5 http://10.88.0.2:9100/hostname")
        for port in [5424, 8500, 9100]:
            internet.fail(f"timeout 5 bash -c 'exec 3<>/dev/tcp/{machine_vlan}/{port}'")
  '';
}
