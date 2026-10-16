{
  lib,
  buildFromTranscript,
}: let
  # Share releases are immutable, so the release version pins the client library.
  # deploy-program.u names the base release this one depends on (`unison_base_7_12_1`),
  # so a bump may need that name changed too.
  cloudRelease = "27.3.1";
in
  buildFromTranscript {
    pname = "deploy-program";
    version = cloudRelease;

    src = lib.fileset.toSource {
      root = ./.;
      fileset = ./deploy-program.u;
    };
    transcript = builtins.toFile "deploy-program-compile.md" ''
      ```ucm
      scratch/main> lib.install @unison/cloud/releases/${cloudRelease}
      scratch/main> load deploy-program.u
      scratch/main> update
      scratch/main> compile deployProgram.main deploy-program
      ```
    '';

    compiledHash = "sha256-t5btVAezsAx4xDIZcA+9Ep81YklUxjzEBi6Dl6DJX7Q=";

    meta.mainProgram = "deploy-program";
  }
