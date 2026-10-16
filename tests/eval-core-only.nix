# Evaluates hosts that import core alone, the way your NixOS configs do, and checks the
# assertions that guard its required options. Returns the systems' derivation paths.
{
  self,
  nixpkgs,
  system,
}: let
  inherit (nixpkgs) lib;

  suppliedSecrets = [
    "cloud-api-db-password"
    "nimbus-db-password"
    "s3-access-key-id"
    "s3-secret-access-key"
    "oidc-client-secret"
    "consul-token"
  ];
  files = names: lib.genAttrs names (name: "/run/secrets/${name}");

  base = {
    nixpkgs.hostPlatform = system;
    boot.loader.grub.enable = false;
    fileSystems."/" = {
      device = "/dev/vda";
      fsType = "ext4";
    };
    system.stateVersion = "26.11";

    services.unison-cloud = {
      enable = true;
      domains = {
        api = "cloud.example.com";
        apps = "apps.example.com";
        ui = "ui.example.com";
      };
      database.host = "db.example.com";
      s3.host = "s3.example.com";
      logs.lokiUrl = "http://loki.example.com:3100";
      auth.oidc = {
        issuer = "https://login.example.com";
        clientId = "unison-cloud";
        allowedGroups = ["unison-cloud"];
      };
      secrets.files = files suppliedSecrets;
    };
  };

  eval = extra: lib.nixosSystem {modules = [self.nixosModules.core base extra];};
  failed = host: map (a: a.message) (lib.filter (a: !a.assertion) host.config.assertions);
  failsWith = text: host: lib.any (lib.hasInfix text) (failed host);
  drvPath = host: builtins.unsafeDiscardStringContext host.config.system.build.toplevel.drvPath;

  minimal = eval {};
  nimbusOnly = eval {
    services.unison-cloud = {
      cloudApi.enable = false;
      nimbus.cloudApiHost = "10.0.0.1";
      advertiseAddress = "10.0.0.2";
    };
  };
  noDatabase = eval {services.unison-cloud.database.host = lib.mkForce null;};
  nimbusOnLoopback = eval {services.unison-cloud.cloudApi.enable = false;};
  noConsulToken = eval {services.unison-cloud.secrets.files = lib.mkForce (files (lib.remove "consul-token" suppliedSecrets));};

  services = minimal.config.systemd.services;
in
  assert lib.assertMsg (failed minimal == []) "a minimal core-only host fails: ${toString (failed minimal)}";
  assert lib.assertMsg (failed nimbusOnly == []) "a nimbus-only host fails: ${toString (failed nimbusOnly)}";
  assert lib.assertMsg (!(nimbusOnly.config.systemd.services ? unison-cloud-api)) "a nimbus-only host runs cloud-api";
  assert lib.assertMsg (failsWith "database.host" noDatabase) "a host without database.host evaluates";
  assert lib.assertMsg (failsWith "nimbus.cloudApiHost" nimbusOnLoopback) "a nimbus-only host pointing at its own loopback evaluates";
  assert lib.assertMsg (failsWith "consul-token" noConsulToken) "a host without consul-token evaluates";
  assert lib.assertMsg (lib.all (name: !(services ? ${name})) [
    "unison-cloud-postgresql"
    "unison-cloud-s3"
    "unison-cloud-loki"
    "unison-cloud-dex"
    "unison-cloud-outbound-proxy"
    "unison-cloud-consul"
    "caddy"
  ]) "core runs a battery";
  assert lib.assertMsg (minimal.config.services.unison-cloud.nimbus.outboundProxy == null) "core sets an outbound proxy";
  assert lib.assertMsg (minimal.config.networking.firewall.allowedTCPPorts == []) "core opens a firewall port";
    lib.concatLines [(drvPath minimal) (drvPath nimbusOnly)]
