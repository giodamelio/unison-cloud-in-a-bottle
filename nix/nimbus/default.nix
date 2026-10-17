{
  lib,
  buildFromTranscript,
}: let
  # nimbus lives on Unison Share, not in git, and has no releases yet, so there is no
  # immutable thing to fetch. Instead this pins a causal hash (Unison's equivalent of a
  # commit) on the `main` branch:
  #
  # 1. `pull` fetches main *with* history, so every earlier causal on the branch ends up
  #    in the local codebase, including this one after main has moved on.
  # 2. `reset` rewinds the local scratch branch to the pinned causal.
  # 3. `compile` writes `nimbus.uc`, which buildFromTranscript wraps as `bin/nimbus`
  #    (`ucm run.compiled nimbus.uc`).
  #
  # buildFromTranscript runs the transcript in a fixed-output derivation so ucm can reach
  # Share. compiledHash is the hash of the compiled `.uc`, which depends on the causal and
  # on the ucm version unison-nix provides. Change either and the hash must be updated:
  # set it to lib.fakeHash, build, and copy the `got:` hash.
  #
  # This breaks only if main's history is rewritten so the pinned causal is no longer
  # an ancestor of main.
  #
  # To move to a newer nimbus, take main's current causalHash from
  # https://api.unison-lang.org/users/unison/projects/nimbus/branches
  causalHash = "bjd01vj11ng56p2p1n2vf1ml127hg3aha3um5motl43avn2hibvobmcke61ajvu88npvm6mrfi536il3jtt50ltlhncao8akjd6eumo";

  # Patches are scratch files in ../../patches/nimbus, copied into the transcript's working
  # directory through `src`. `update` typechecks each one against the pinned causal, so a
  # causal bump that conflicts with a patch fails here as a type error.
  #
  # The PostgreSQL storage patches need @runarorama/postgres, which installs from Share
  # without a token. A release is immutable, so this pins it as firmly as the causal.
  #
  # unison_aws 5.2.0 reads S3 response headers through unison_http 3.6.0, which matches
  # `ETag` only as written or all lowercase, so it misses the `Etag` that Go servers such
  # as Caddy send over HTTP/1.1. 5.2.1 reads them through unison_http 15.2.0, which
  # ignores case, and `upgrade` moves every nimbus definition over to it.
  patchesDir = ../../patches/nimbus;
  prepare = ''
    scratch/main> pull @unison/nimbus/main
    scratch/main> reset #${causalHash}
    scratch/main> load 0002-unproxied-internal-traffic.u
    scratch/main> update
    scratch/main> lib.install @runarorama/postgres/releases/2.5.1
    scratch/main> load 0003-postgres-config.u
    scratch/main> update
    scratch/main> load 0004-postgres-storage.u
    scratch/main> update
    scratch/main> lib.install @unison/aws/releases/5.2.1
    scratch/main> upgrade unison_aws_5_2_0 unison_aws_5_2_1
    scratch/main> load 0005-s3-content-type.u
    scratch/main> update
  '';
in
  (buildFromTranscript {
    pname = "nimbus";
    version = "0-unstable-2026-10-08";

    src = patchesDir;
    transcript = builtins.toFile "nimbus-compile.md" ''
      ```ucm
      ${prepare}
      scratch/main> compile main.nodeMain nimbus
      ```
    '';

    compiledHash = "sha256-jYwdyf6h+Ak7OQGN1ReKfrIzDI2tBKeO/F3XwmkJqAM=";

    meta = {
      description = "Unison Cloud worker node";
      homepage = "https://share.unison-lang.org/@unison/nimbus";
      license = lib.licenses.mit;
      mainProgram = "nimbus";
    };
  }).overrideAttrs {
    # For compiling other programs against the same patched nimbus, such as test probes.
    passthru = {inherit patchesDir prepare;};
  }
