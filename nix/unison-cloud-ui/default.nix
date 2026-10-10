{
  lib,
  buildNpmPackage,
  importNpmLock,
  elmPackages,
  src,
  version,
  apiUrl,
  websiteUrl,
  servicesUrl,
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

    patches = [
      ../../patches/cloud-ui/0001-remove-intercom.patch
      ../../patches/cloud-ui/0002-remove-billing.patch
      ../../patches/cloud-ui/0003-remove-status-link.patch
      ../../patches/cloud-ui/0004-path-based-service-urls.patch
    ];

    npmDeps = importNpmLock {npmRoot = src;};
    inherit (importNpmLock) npmConfigHook;

    nativeBuildInputs = [elmPackages.elm];

    env = {
      npm_config_ignore_scripts = "true";
      # webpack.prod.js falls back to the hosted unison.cloud endpoints when these are unset.
      API_URL = apiUrl;
      WEBSITE_URL = websiteUrl;
      SERVICES_URL = servicesUrl;
    };

    preConfigure = ''
      mkdir -p elm-stuff/gitdeps/github.com/unisonweb
      cp -r ${uiCoreSrc} elm-stuff/gitdeps/github.com/unisonweb/ui-core
      chmod -R +w elm-stuff/gitdeps
    '';

    # Regenerate elm-srcs.nix and registry.dat with `elm2nix convert` and `elm2nix snapshot` when elm.json changes.
    postConfigure = elmPackages.fetchElmDeps {
      elmVersion = elmPackages.elm.version;
      elmPackages = import ./elm-srcs.nix;
      registryDat = ./registry.dat;
    };

    # The npm elm package only ships prebuilt binaries for x86_64 Linux, and elm-webpack-loader
    # runs whichever `elm` npm puts first on PATH, so nixpkgs' compiler replaces it. nixpkgs
    # only has a newer elm than the UI pins, and elm refuses to build for a different version.
    preBuild = ''
      ln -sf ${elmPackages.elm}/bin/elm node_modules/.bin/elm
      substituteInPlace elm.json --replace-fail '"elm-version": "${elmJson.elm-version}"' '"elm-version": "${elmPackages.elm.version}"'
    '';

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
