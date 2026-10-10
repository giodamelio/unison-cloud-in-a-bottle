{
  lib,
  rustPlatform,
  cmake,
  src,
  gitRev,
  buildTime,
}: let
  cargoToml = lib.importTOML (src + "/Cargo.toml");
in
  rustPlatform.buildRustPackage {
    pname = "extenddb";
    inherit (cargoToml.workspace.package) version;
    inherit src;

    cargoLock.lockFile = src + "/Cargo.lock";

    nativeBuildInputs = [cmake];

    cargoBuildFlags = ["-p" "extenddb"];
    cargoTestFlags = ["-p" "extenddb"];

    # build.rs otherwise shells out to git and stamps the current time.
    env = {
      EXTENDDB_GIT_HASH = gitRev;
      EXTENDDB_BUILD_TIME = buildTime;
    };

    meta = {
      description = "DynamoDB-compatible API backed by PostgreSQL";
      homepage = "https://github.com/ExtendDB/extenddb";
      license = lib.licenses.asl20;
      mainProgram = "extenddb";
    };
  }
