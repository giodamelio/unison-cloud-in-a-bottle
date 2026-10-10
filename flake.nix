{
  description = "Unison Cloud as a in a NixOS module";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";

    unison-nix.url = "github:ceedubs/unison-nix";
    unison-nix.inputs.nixpkgs.follows = "nixpkgs";

    unison-cloud-ui.url = "github:unisonweb/unison-cloud-ui";
    unison-cloud-ui.flake = false;

    extenddb.url = "github:ExtendDB/extenddb/v0.1.13";
    extenddb.flake = false;
  };

  outputs = inputs: let
    systems = ["x86_64-linux" "aarch64-linux"];
    forAllSystems = f: inputs.nixpkgs.lib.genAttrs systems (system: f inputs.nixpkgs.legacyPackages.${system});
  in {
    packages = forAllSystems (pkgs: {
      unison-cloud-ui = pkgs.callPackage ./nix/unison-cloud-ui {
        src = inputs.unison-cloud-ui;
        version = "0-unstable-${inputs.unison-cloud-ui.lastModifiedDate}";
      };

      extenddb = pkgs.callPackage ./nix/extenddb {
        src = inputs.extenddb;
        gitRev = inputs.extenddb.shortRev;
        buildTime = let
          d = inputs.extenddb.lastModifiedDate;
          s = builtins.substring;
        in "${s 0 4 d}-${s 4 2 d}-${s 6 2 d}T${s 8 2 d}:${s 10 2 d}:${s 12 2 d}Z";
      };
    });

    devShells = forAllSystems (pkgs: let
      unison = inputs.unison-nix.packages.${pkgs.stdenv.hostPlatform.system};
    in {
      default = pkgs.mkShell {
        packages = [
          unison.ucm-bin
          unison.ucm-desktop
        ];
      };
    });
  };
}
