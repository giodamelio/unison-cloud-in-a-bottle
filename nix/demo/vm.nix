{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: let
  cfg = config.services.unison-cloud;
  url = cfg.internal.publicUrl;
  port = cfg.ingress.port;
in {
  imports = ["${modulesPath}/virtualisation/qemu-vm.nix"];

  # The module always runs the bundled Consul, which nixpkgs marks unfree (BSL 1.1).
  nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "consul";

  networking.hostName = "unison-cloud-demo";

  virtualisation = {
    memorySize = 6144;
    cores = 4;
    diskSize = 8192;
    graphics = false;
    # Bound to loopback so the demo stays off the LAN. The same port inside and out keeps
    # every public URL identical on both sides.
    forwardPorts = [
      {
        from = "host";
        host.address = "127.0.0.1";
        host.port = port;
        guest.port = port;
      }
    ];
  };

  services.getty.autologinUser = "root";

  users.motd = ''

    Unison Cloud demo

      UI:    ${url.ui}
      API:   ${url.api}
      Login: demo@unison.localhost / demo
      Hello: the demo user's pre-deployed service, URL in /var/lib/unison-cloud-demo/hello-url
      Admin: admin@${cfg.domains.api}, password in ${cfg.stateDir}/secrets/dex-admin-password

  '';

  # The run script reads the generated admin password from the host's side of /tmp/xchg.
  systemd.services.unison-cloud-demo-admin-password = {
    description = "Share the generated admin password with the demo's run script";
    wantedBy = ["multi-user.target"];
    requires = ["unison-cloud-secrets.service"];
    after = ["unison-cloud-secrets.service"];
    unitConfig.RequiresMountsFor = "/tmp/xchg";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${lib.getExe' pkgs.coreutils "cp"} ${cfg.stateDir}/secrets/dex-admin-password /tmp/xchg/dex-admin-password";
    };
  };

  # The run script prints the pre-deployed service's URL from the same shared directory.
  systemd.services.unison-cloud-demo-hello-url = {
    description = "Share the demo's hello service URL with the demo's run script";
    wantedBy = ["multi-user.target"];
    requires = ["unison-cloud-demo-hello.service"];
    after = ["unison-cloud-demo-hello.service"];
    unitConfig.RequiresMountsFor = "/tmp/xchg";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${lib.getExe' pkgs.coreutils "cp"} /var/lib/unison-cloud-demo/hello-url /tmp/xchg/hello-url";
    };
  };

  system.stateVersion = "26.11";
}
