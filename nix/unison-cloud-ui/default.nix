{
  lib,
  buildNpmPackage,
  importNpmLock,
  elmPackages,
  src,
  version,
}: let
  elmJson = lib.importJSON (src + "/elm.json");
  elmGitJson = lib.importJSON (src + "/elm-git.json");

  # Follows whatever ui-core rev the UI pins, so bumping the src input needs no hash update here.
  uiCoreSrc = builtins.fetchGit {
    url = "https://github.com/unisonweb/ui-core";
    rev = elmGitJson.git-dependencies.direct."https://github.com/unisonweb/ui-core";
    allRefs = true;
  };
in
  buildNpmPackage {
    pname = "unison-cloud-ui";
    inherit version src;

    npmDeps = importNpmLock {npmRoot = src;};
    npmConfigHook = importNpmLock.npmConfigHook;

    nativeBuildInputs = [elmPackages.elm];

    env.npm_config_ignore_scripts = "true";

    preConfigure = ''
      mkdir -p elm-stuff/gitdeps/github.com/unisonweb
      cp -r ${uiCoreSrc} elm-stuff/gitdeps/github.com/unisonweb/ui-core
      chmod -R +w elm-stuff/gitdeps
    '';

    # Regenerate elm-srcs.nix and registry.dat with `elm2nix convert` and `elm2nix snapshot` when elm.json changes.
    postConfigure = elmPackages.fetchElmDeps {
      elmVersion = elmJson.elm-version;
      elmPackages = import ./elm-srcs.nix;
      registryDat = ./registry.dat;
    };

    installPhase = ''
      runHook preInstall
      cp -r dist/unisonCloud $out
      runHook postInstall
    '';

    meta = {
      description = "Web UI for Unison Cloud";
      homepage = "https://github.com/unisonweb/unison-cloud-ui";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
    };
  }
