{
  lib,
  buildFromTranscript,
}: let
  # The same @unison/cloud release as the test client in tests/deploy-program.
  cloudRelease = "27.3.1";
in
  buildFromTranscript {
    pname = "unison-cloud-demo-hello";
    version = cloudRelease;

    src = lib.fileset.toSource {
      root = ./.;
      fileset = ./hello.u;
    };
    transcript = builtins.toFile "demo-hello-compile.md" ''
      ```ucm
      scratch/main> lib.install @unison/cloud/releases/${cloudRelease}
      scratch/main> load hello.u
      scratch/main> update
      scratch/main> compile demoHello.main demo-hello
      ```
    '';

    compiledHash = "sha256-c5wgwKFJOWCpAYkzpPZ5YYKp5fWQKr859yYDi5g6pYY=";

    meta.mainProgram = "demo-hello";
  }
