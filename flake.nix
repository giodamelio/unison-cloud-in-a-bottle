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

    demoName = system:
      if system == "x86_64-linux"
      then "demo"
      else "demo-${system}";
    demoFor = pkgs: inputs.self.nixosConfigurations.${demoName pkgs.stdenv.hostPlatform.system};
    demoRun = pkgs: pkgs.callPackage ./nix/demo/run.nix {nixos = demoFor pkgs;};
    demoLogin = pkgs:
      pkgs.callPackage ./nix/demo/login.nix {
        nixos = demoFor pkgs;
        ucm = inputs.unison-nix.packages.${pkgs.stdenv.hostPlatform.system}.ucm-bin;
      };
  in {
    nixosModules.default = import ./nixos inputs.self;

    nixosConfigurations = inputs.nixpkgs.lib.listToAttrs (map (system:
      inputs.nixpkgs.lib.nameValuePair (demoName system) (inputs.nixpkgs.lib.nixosSystem {
        modules = [
          (import ./nix/demo/configuration.nix inputs.self)
          ./nix/demo/vm.nix
          {nixpkgs.hostPlatform = system;}
        ];
      }))
    systems);

    apps = forAllSystems (pkgs: {
      demo = {
        type = "app";
        program = pkgs.lib.getExe (demoRun pkgs);
        meta.description = "Boot the self-hosted Unison Cloud demo VM and print its URLs and login";
      };

      demo-login = {
        type = "app";
        program = pkgs.lib.getExe (demoLogin pkgs);
        meta.description = "Log ucm in to the running demo VM, for deploying with the cloud client";
      };
    });

    checks = forAllSystems (defaultPkgs: let
      # The module always runs the bundled Consul, which nixpkgs marks unfree (BSL 1.1).
      pkgs = import inputs.nixpkgs {
        inherit (defaultPkgs.stdenv.hostPlatform) system;
        config.allowUnfreePredicate = pkg: inputs.nixpkgs.lib.getName pkg == "consul";
      };
      lint = name: nativeBuildInputs: command:
        pkgs.runCommand "lint-${name}" {inherit nativeBuildInputs;} ''
          cd ${inputs.self}
          ${command}
          touch $out
        '';
    in {
      lint-actionlint = lint "actionlint" [pkgs.actionlint pkgs.shellcheck] "actionlint .github/workflows/*.yml";
      lint-alejandra = lint "alejandra" [inputs.self.formatter.${pkgs.stdenv.hostPlatform.system}] "fmt --check .";
      lint-deadnix = lint "deadnix" [pkgs.deadnix] "deadnix --fail .";
      lint-statix = lint "statix" [pkgs.statix] "statix check .";
      # Forcing the drvPath evaluates the whole aarch64 demo, which catches ARM breakage on
      # any runner. The context is discarded because a drvPath's context makes the check
      # depend on every build input of the demo, which means building it.
      lint-eval-demo-aarch64 =
        pkgs.writeText "lint-eval-demo-aarch64"
        (builtins.unsafeDiscardStringContext inputs.self.nixosConfigurations.demo-aarch64-linux.config.system.build.vm.drvPath);

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

      demo = pkgs.testers.runNixOSTest (import ./tests/demo.nix {
        inherit (inputs) self;
        deployProgram = pkgs.callPackage ./tests/deploy-program {
          inherit (inputs.unison-nix.packagesLib.${pkgs.stdenv.hostPlatform.system}) buildFromTranscript;
        };
      });
    });

    # alejandra.toml has no exclude option, so the excludes live here. tmp/ holds gitignored
    # reference clones, and elm-srcs.nix is generated by elm2nix.
    formatter = forAllSystems (pkgs:
      pkgs.writeShellApplication {
        name = "fmt";
        runtimeInputs = [pkgs.alejandra];
        text = ''
          alejandra --exclude ./tmp --exclude ./nix/unison-cloud-ui/elm-srcs.nix "''${@:-.}"
        '';
      });

    packages = forAllSystems (pkgs: {
      unison-cloud-ui = pkgs.callPackage ./nix/unison-cloud-ui {
        src = inputs.unison-cloud-ui;
        version = "0-unstable-${inputs.unison-cloud-ui.lastModifiedDate}";
        # Placeholders so the package builds standalone; the NixOS module overrides all three.
        apiUrl = "https://cloud.example.com/v2";
        websiteUrl = "https://ui.example.com";
        servicesUrl = "https://apps.example.com/services";
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
        packages =
          removeAttrs inputs.self.packages.${pkgs.stdenv.hostPlatform.system} ["push-cache"]
          // {
            demo-vm = (demoFor pkgs).config.system.build.vm;
            demo-run = demoRun pkgs;
            demo-login = demoLogin pkgs;
            demo-shell = inputs.self.devShells.${pkgs.stdenv.hostPlatform.system}.demo.inputDerivation;
          };
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

      demo = let
        cfg = (demoFor pkgs).config.services.unison-cloud;
      in
        pkgs.mkShell {
          packages = [unison.ucm-bin (demoLogin pkgs)];
          UNISON_CLOUD_HOST = cfg.domains.api;
          UNISON_CLOUD_HTTP_PORT = toString cfg.ingress.port;
          UNISON_CLOUD_USE_TLS = "false";
          # ucm stores `auth.login` credentials under the codeserver's host and port.
          UNISON_CLOUD_CREDENTIALS_HOST = "${cfg.domains.api}:${toString cfg.ingress.port}";
        };
    });
  };
}
