{
  config,
  lib,
  ...
}: let
  cfg = config.services.unison-cloud;
in {
  options.services.unison-cloud.internal.redisPort = lib.mkOption {
    type = lib.types.port;
    internal = true;
    readOnly = true;
    default = 6379;
    description = "Port the bundled Redis listens on, on the namespace loopback.";
  };

  config = lib.mkIf cfg.enable {
    # Hosted code shares the namespace's loopback with nimbus, so Redis needs a password
    # even though nothing outside the namespace can reach it.
    services.redis.servers.unison-cloud = {
      enable = true;
      bind = "127.0.0.1";
      port = cfg.internal.redisPort;
      # Read by the unit's own privileged ExecStartPre, after systemd has loaded it.
      requirePassFile = "/run/credentials/redis-unison-cloud.service/redis-password";
    };

    systemd.services.redis-unison-cloud = lib.mkMerge [
      cfg.internal.inNamespace
      {
        requires = ["unison-cloud-secrets.service"];
        after = ["unison-cloud-secrets.service"];
        serviceConfig = cfg.internal.loadSecrets ["redis-password"];
      }
    ];
  };
}
