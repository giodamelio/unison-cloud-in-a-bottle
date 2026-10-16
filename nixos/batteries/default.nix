self: {
  # Importing core here means batteries works alone, and its key means importing both
  # still loads core once.
  key = "unison-cloud-nix/batteries";

  imports = [
    (import ../core self)
    ./postgresql.nix
    ./s3.nix
    ./loki.nix
    ./dex.nix
    ./caddy.nix
    ./squid.nix
    ./consul.nix
  ];
}
