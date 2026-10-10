self: {
  config,
  pkgs,
  ...
}: let
  cfg = config.services.unison-cloud;
in {
  imports = [self.nixosModules.default];

  services.unison-cloud = {
    enable = true;
    # One parent domain on purpose: the session cookie is SameSite=Lax without a Domain,
    # so the UI's requests only carry it when the UI and API are the same site.
    domains = {
      api = "cloud.unison.localhost";
      apps = "apps.unison.localhost";
      ui = "ui.unison.localhost";
    };
    ingress = {
      scheme = "http";
      port = 8080;
    };
    auth.dex.users = [
      {
        email = "demo@unison.localhost";
        username = "demo";
        # A literal rather than a hash built at evaluation time: bcrypt salts randomly, so
        # a built hash would change the VM's store paths on every build.
        passwordHashFile = pkgs.writeText "unison-cloud-demo-password.bcrypt" "$2b$10$/Lfz.yT3xdZwUBTJwkK29ObMuNl5lrS2rHlKJkJk054huJV4Vb9gm";
      }
    ];
  };

  networking.nftables.enable = true;
  networking.firewall.allowedTCPPorts = [cfg.ingress.port];
}
