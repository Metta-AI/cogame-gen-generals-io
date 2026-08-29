# AGENTS.md — working on cogame-gen-generals-io

Forked from `Metta-AI/coworld-ctf` (paintbot). Read `docs/plans/2026-08-28-gen-generals-io-design.md`
first: it is the note this repo was built from and it decides every rule.

## The shape of the thing

* `src/generals/` is the sim, the decision layer and the server. It compiles
  **twice**: natively into `/bin/gen-generals-io`, and to wasm through
  `replay-viewer/config.nims` for the browser viewer. Anything you add to the
  sim path must compile under `--cpu:wasm32` too, where Nim's `int` is 32 bits.
* **The sim path is integer only.** `tests/test_gen_determinism.nim` greps
  `sim`, `board`, `vision`, `resolve`, `scoring`, `captain` and `baselines`
  for a floating point routine and fails the build on one. The placement
  points that turn a rank into `results.scores` live in `roster.nim`, at
  serialisation time.
* **The captain reads `SeatView`, never the board.** `test_gen_captain.nim`
  runs it twice on the same state — once normally, once with every cell
  outside `visible ∪ remembered` replaced by garbage — and requires the
  identical move. That test is what makes the fog real.
* **Truncate on RUNE boundaries.** Never slice a string that can reach the
  replay by byte index; `truncateRunes` / `sanitizeNote` exist for this.

## A GameVersion number is claimed across BRANCHES

`GameVersion` in `src/generals/sim_types.nim` identifies the RULES a replay
was produced by. Two branches can each be current with `main` and still pick
the same next number. `tools/ci/check_gameversion.sh <base>` compares the
number AND the rule headline on the changelog comment; same number plus a
different headline is a collision. Bump it whenever a recorded plan would
re-derive a different board.

## The chrome is inherited, not written

* `client/chrome_common.js` is coworld-ctf's plus the fleet-wide replay
  transport patch (the 0.5x speed chip and its SPEEDS fallback), pinned by
  sha256 in `tests/test_gen_viewer.nim`. Never edit it otherwise. Its line
  72 reads `window.CTF_WIRE`, which is why `tools/gen_wire_constants.nim`
  emits `window.GEN_WIRE={…}` and then one alias line.
* `client/broadcast_core.js` is the starter's generic sprite/layer renderer
  with exactly one line changed (the wire constants it reads).
* `client/replay_broadcast.html` is DERIVED:
  `tools/build_broadcast_page.py <ctf page> client/gen_block.html client/replay_broadcast.html`.
  Edit `client/gen_block.html` (the appended game block) or the script's
  documented cut list, then re-run it and commit both. A from-scratch page
  that reuses the starter's ids is a rewrite and fails review.

## The replay is the contract

Binary `COWLDGEN`. The **plan input records** are load-bearing; everything
else is presentation, with one documented exception — the `stop` record, a
wall-clock fact no re-simulation can derive, applied on both sides by
`sim.applyWallClockStop`. `tests/test_gen_replay.nim` records an episode for
every end reason and requires the re-simulation to reproduce **every**
recorded `gameHash`.

## Running things

The sandbox that built this repo had no Docker, no Nim and no emsdk: `ci.yml`
is the harness. With a toolchain:

```bash
nim r --hints:off --path:src tests/test_gen_resolve.nim   # any one test
./tools/ci/docker_smoke.sh coworld-gen-generals-io:ci     # one real episode
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
node tools/ci/viewer_smoke.mjs --bundle dist/static-replay-viewer \
  --replay dist/smoke/replay.json --timeout 90 --soak 10 --strict-text-bounds
nim r --path:src tools/tune_baselines.nim --check         # the baseline claim
python3 tools/replay_summary.py some.replay | jq .        # forensics
```
