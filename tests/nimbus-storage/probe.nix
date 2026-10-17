{
  runCommand,
  buildFromTranscript,
  nimbus,
}:
buildFromTranscript {
  pname = "storage-probe";
  inherit (nimbus) version;

  src = runCommand "storage-probe-src" {} ''
    mkdir $out
    cp ${nimbus.patchesDir}/* $out/
    cp ${./probe.u} $out/probe.u
  '';
  transcript = builtins.toFile "storage-probe-compile.md" ''
    ```ucm
    ${nimbus.prepare}
    scratch/main> load probe.u
    scratch/main> update
    scratch/main> compile storageProbe storage-probe
    ```
  '';

  compiledHash = "sha256-ivXqvCBv+HSM+ve4li+aqc0ybO1Ql8/oIkKPbMwmxjA=";
}
