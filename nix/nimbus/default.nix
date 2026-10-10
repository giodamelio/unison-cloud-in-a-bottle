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
in
  buildFromTranscript {
    pname = "nimbus";
    version = "0-unstable-2026-10-08";

    transcript = builtins.toFile "nimbus-compile.md" ''
      ```ucm
      scratch/main> pull @unison/nimbus/main
      scratch/main> reset #${causalHash}
      scratch/main> compile main.nodeMain nimbus
      ```
    '';

    compiledHash = "sha256-udpirAX/Vbmlea9Ynk95gtXY6VndRHhcogUN3KAYDmA=";

    meta = {
      description = "Unison Cloud worker node";
      homepage = "https://share.unison-lang.org/@unison/nimbus";
      license = lib.licenses.mit;
      mainProgram = "nimbus";
    };
  }
