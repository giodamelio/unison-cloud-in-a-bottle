{
  applyPatches,
  haskell,
  libpq,
  runCommand,
  stacklock2nix,
  src,
  stdenv,
}: let
  patches = [
    ../../patches/cloud-api/0001-remove-unused-api-types.patch
    ../../patches/cloud-api/0002-production-mode-fixes.patch
    ../../patches/cloud-api/0003-vault-to-postgres.patch
    ../../patches/cloud-api/0004-selfhost-user-provisioning.patch
    ../../patches/cloud-api/0005-environment-access-check.patch
    ../../patches/cloud-api/0006-cookie-secure-from-origin.patch
    ../../patches/cloud-api/0007-oidc-broker.patch
    ../../patches/cloud-api/0008-remove-unauthenticated-routes.patch
    ../../patches/cloud-api/0009-redis-to-postgres.patch
    ../../patches/cloud-api/0010-consul-token-and-prefix.patch
    ../../patches/cloud-api/0011-pkce-verifier-length.patch
  ];

  stacklock = stacklock2nix {
    stackYaml = src + "/stack.yaml";
    # postgresql-libpq links the C libpq, but inside the Haskell package set the name
    # resolves to the unrelated (and broken) Hackage package libpq.
    cabal2nixArgsOverrides = args:
      args
      // {
        "postgresql-libpq" = _version: {inherit libpq;};
      };
    additionalHaskellPkgSetOverrides = _: hprev: {
      cloud = haskell.lib.appendPatches hprev.cloud patches;

      # Its tests need tmp-postgres, which isn't in the snapshot and is marked broken in nixpkgs.
      hasql-interpolate = haskell.lib.dontCheck hprev.hasql-interpolate;
      # Their tests need a running PostgreSQL server.
      hasql = haskell.lib.dontCheck hprev.hasql;
      hasql-pool = haskell.lib.dontCheck hprev.hasql-pool;
      postgresql-binary = haskell.lib.dontCheck hprev.postgresql-binary;
      # Its tests pull in wreq -> snap-server <-> http-streams, whose test suites depend on each other.
      servant-auth-server = haskell.lib.dontCheck hprev.servant-auth-server;
      # Its tests need tasty >=1.5; the snapshot has 1.4. Its Setup.hs locates libpq with pg_config.
      postgresql-libpq = haskell.lib.addBuildTool (haskell.lib.dontCheck hprev.postgresql-libpq) libpq.pg_config;
      # Its tests need hspec <2.11; the snapshot has a newer one.
      http-api-data = haskell.lib.dontCheck hprev.http-api-data;
      # Its tests run scripts/local-htfpp as a preprocessor, which the Hackage tarball ships without the executable bit.
      HTF = haskell.lib.dontCheck hprev.HTF;
      # Its "Large - Pinned" tests fail under GHC 9.6.7.
      pvar = haskell.lib.dontCheck hprev.pvar;
      # Its tests don't compile against the snapshot's QuickCheck.
      xmlgen = haskell.lib.dontCheck hprev.xmlgen;
      # On aarch64 its native toHalf and the C one encode NaN with different bits, which its
      # tests compare. Skipped only there so the x86_64 build keeps its cached hashes.
      half =
        if stdenv.hostPlatform.isAarch64
        then haskell.lib.dontCheck hprev.half
        else hprev.half;
      # Its cbits declare `void check_impl_specific();` and define it with arguments, which
      # C23 (GCC 15's default) rejects. Fixed upstream in 1.4, but the snapshot pins 1.3.1.
      hashtables = haskell.lib.appendConfigureFlag hprev.hashtables "--ghc-option=-optc-std=gnu17";
    };
    # lts-22.26 targets GHC 9.6.5; nixpkgs only carries the latest 9.6 point release.
    baseHaskellPkgSet = haskell.packages.ghc96;
  };

  # The migrations aren't part of the Haskell build output, but the module's migrate unit
  # needs them, including the ones the patches add.
  sql = runCommand "cloud-api-sql" {} ''
    cp -r ${applyPatches {
      name = "cloud-api-patched-src";
      inherit src patches;
    }}/docker/sql $out
  '';
in
  (haskell.lib.justStaticExecutables stacklock.pkgSet.cloud).overrideAttrs (old: {
    passthru = old.passthru // {inherit sql;};
  })
