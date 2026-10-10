{
  runCommand,
  buildFromTranscript,
  nimbus,
}:
buildFromTranscript {
  pname = "dynamo-probe";
  inherit (nimbus) version;

  src = runCommand "dynamo-probe-src" {} ''
    mkdir $out
    cp ${nimbus.patchesDir}/* $out/
    cp ${./probe.u} $out/probe.u
  '';
  transcript = builtins.toFile "dynamo-probe-compile.md" ''
    ```ucm
    ${nimbus.prepare}
    scratch/main> load probe.u
    scratch/main> update
    scratch/main> compile dynamoProbe dynamo-probe
    ```
  '';

  compiledHash = "sha256-Kx093PIzev7+7favsfoPyoGlXtP6hLmscoA1L7bYnYM=";
}
