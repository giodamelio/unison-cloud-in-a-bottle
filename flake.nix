{
  description = "Unison Cloud as a in a NixOS module";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";

    unison-nix.url = "github:ceedubs/unison-nix";
    unison-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs: let
    systems = ["x86_64-linux" "aarch64-linux"];
    forAllSystems = f: inputs.nixpkgs.lib.genAttrs systems (system: f inputs.nixpkgs.legacyPackages.${system});
  in {
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
