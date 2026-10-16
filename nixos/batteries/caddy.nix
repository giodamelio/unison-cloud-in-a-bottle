{
  config,
  lib,
  ...
}: let
  cfg = config.services.unison-cloud;
  site = cfg.caddy.siteConfig;
  # Caddy sorts handle blocks by their path, so this one goes first wherever it sits.
  dexHandle = lib.optionalString cfg.batteries.dex.enable ''
    handle /dex/* {
      reverse_proxy 127.0.0.1:${toString cfg.batteries.dex.port}
    }
  '';
in {
  options.services.unison-cloud.batteries.caddy.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Serve the API, apps and UI domains through `services.caddy`, with the bundled Dex
      under `/dex` on the API domain.
    '';
  };

  config.services.caddy = lib.mkIf (cfg.enable && cfg.batteries.caddy.enable) {
    enable = true;
    virtualHosts =
      {
        ${cfg.internal.publicUrl.api}.extraConfig = dexHandle + site.api;
        ${cfg.internal.publicUrl.ui}.extraConfig = site.ui;
      }
      // lib.optionalAttrs (site.apps != "") {
        ${cfg.internal.publicUrl.apps}.extraConfig = site.apps;
      };
  };
}
