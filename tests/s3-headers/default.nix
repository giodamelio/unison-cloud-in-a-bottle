# Runs nimbus's own S3 calls against stubbed responses in the shape Caddy sends for
# Garage over HTTP/1.1, so a deploy and a blob round trip need no S3 server to check.
{
  runCommand,
  buildFromTranscript,
  nimbus,
}: let
  probe = buildFromTranscript {
    pname = "s3-headers-probe";
    inherit (nimbus) version;

    src = runCommand "s3-headers-probe-src" {} ''
      mkdir $out
      cp ${nimbus.patchesDir}/* $out/
      cp ${./probe.u} $out/probe.u
    '';
    transcript = builtins.toFile "s3-headers-probe-compile.md" ''
      ```ucm
      ${nimbus.prepare}
      scratch/main> load probe.u
      scratch/main> update
      scratch/main> compile s3HeadersProbe s3-headers-probe
      ```
    '';

    compiledHash = "";
  };
in
  runCommand "s3-headers" {} ''
    ${probe}/bin/s3-headers-probe | tee output
    etag='"ab9616d85327c4b9bb465db1917fe162"'
    grep -qxF "servicePut=$etag" output
    grep -qxF "blobPut=$etag" output
    grep -qxF "blobRead=$etag application/octet-stream" output
    touch $out
  ''
