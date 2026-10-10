{
  lib,
  writeShellApplication,
  cachix,
  packages,
  cacheName ? "unison-cloud-in-a-bottle",
}:
writeShellApplication {
  name = "push-cache";
  runtimeInputs = [cachix];
  text = ''
    cachix push ${cacheName} ${lib.escapeShellArgs (lib.attrValues packages)} "$@"
  '';
}
