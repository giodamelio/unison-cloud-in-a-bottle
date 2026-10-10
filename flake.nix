{
  description = "Unison Cloud as a in a NixOS module";

  nixConfig = {
    extra-substituters = ["https://unison-cloud-in-a-bottle.cachix.org"];
    extra-trusted-public-keys = ["unison-cloud-in-a-bottle.cachix.org-1:egpjVQf3JrKM0bo39Gh3JKOMeEbyyk8t0VSH6455r8w="];
  };

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";

    unison-nix.url = "github:ceedubs/unison-nix";
    unison-nix.inputs.nixpkgs.follows = "nixpkgs";

    unison-cloud-ui.url = "github:unisonweb/unison-cloud-ui";
    unison-cloud-ui.flake = false;

    cloud-api.url = "github:unisonweb/cloud-api";
    cloud-api.flake = false;

    stacklock2nix.url = "github:cdepillabout/stacklock2nix/v5.2.3";

    extenddb.url = "github:ExtendDB/extenddb/v0.1.13";
    extenddb.flake = false;
  };

  outputs = inputs: let
    systems = ["x86_64-linux" "aarch64-linux"];
    forAllSystems = f: inputs.nixpkgs.lib.genAttrs systems (system: f inputs.nixpkgs.legacyPackages.${system});
  in {
    nixosModules.default = import ./nixos inputs.self;

    checks = forAllSystems (defaultPkgs: let
      # The module always runs the bundled Consul, which nixpkgs marks unfree (BSL 1.1).
      pkgs = import inputs.nixpkgs {
        inherit (defaultPkgs.stdenv.hostPlatform) system;
        config.allowUnfreePredicate = pkg: inputs.nixpkgs.lib.getName pkg == "consul";
      };
    in {
      extenddb = pkgs.testers.runNixOSTest (import ./tests/extenddb.nix inputs.self);

      cloud-api-boot = pkgs.testers.runNixOSTest (import ./tests/cloud-api-boot.nix inputs.self);

      auth = pkgs.testers.runNixOSTest (import ./tests/auth.nix inputs.self);

      variants = pkgs.testers.runNixOSTest (import ./tests/variants.nix {
        inherit (inputs) self;
        deployProgram = pkgs.callPackage ./tests/deploy-program {
          inherit (inputs.unison-nix.packagesLib.${pkgs.stdenv.hostPlatform.system}) buildFromTranscript;
        };
      });

      namespace = pkgs.testers.runNixOSTest (import ./tests/namespace.nix inputs.self);

      nimbus-dynamo = pkgs.testers.runNixOSTest (import ./tests/nimbus-dynamo {
        inherit (inputs) self;
        dynamoProbe = pkgs.callPackage ./tests/nimbus-dynamo/probe.nix {
          inherit (inputs.unison-nix.packagesLib.${pkgs.stdenv.hostPlatform.system}) buildFromTranscript;
          inherit (inputs.self.packages.${pkgs.stdenv.hostPlatform.system}) nimbus;
        };
      });

      nimbus-single = pkgs.testers.runNixOSTest (import ./tests/nimbus-single.nix {
        inherit (inputs) self;
        deployProgram = pkgs.callPackage ./tests/deploy-program {
          inherit (inputs.unison-nix.packagesLib.${pkgs.stdenv.hostPlatform.system}) buildFromTranscript;
        };
      });

      full = pkgs.testers.runNixOSTest (import ./tests/full.nix {
        inherit (inputs) self;
        deployProgram = pkgs.callPackage ./tests/deploy-program {
          inherit (inputs.unison-nix.packagesLib.${pkgs.stdenv.hostPlatform.system}) buildFromTranscript;
        };
      });
    });

    packages = forAllSystems (pkgs: {
      unison-cloud-ui = pkgs.callPackage ./nix/unison-cloud-ui {
        src = inputs.unison-cloud-ui;
        version = "0-unstable-${inputs.unison-cloud-ui.lastModifiedDate}";
        # Placeholders so the package builds standalone; the NixOS module overrides both.
        apiUrl = "https://cloud.example.com/v2";
        websiteUrl = "https://ui.example.com";
      };

      cloud-api = pkgs.callPackage ./nix/cloud-api {
        src = inputs.cloud-api;
        stacklock2nix = pkgs.callPackage "${inputs.stacklock2nix}/nix/build-support/stacklock2nix" {};
      };

      extenddb = pkgs.callPackage ./nix/extenddb {
        src = inputs.extenddb;
        gitRev = inputs.extenddb.shortRev;
        buildTime = let
          d = inputs.extenddb.lastModifiedDate;
          s = builtins.substring;
        in "${s 0 4 d}-${s 4 2 d}-${s 6 2 d}T${s 8 2 d}:${s 10 2 d}:${s 12 2 d}Z";
      };

      nimbus = pkgs.callPackage ./nix/nimbus {
        inherit (inputs.unison-nix.packagesLib.${pkgs.stdenv.hostPlatform.system}) buildFromTranscript;
      };

      push-cache = pkgs.callPackage ./nix/push-cache {
        packages = removeAttrs inputs.self.packages.${pkgs.stdenv.hostPlatform.system} ["push-cache"];
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
