# cogame-gen-generals-io

**Four crowns, one grid, and a fog you have to walk into.**

`gen-generals-io` is a four-seat, free-for-all, fog-of-war conquest game on a
16 × 10 grid — a standalone generals.io-style coworld. Every commander starts
on one crowned tile in one corner of a four-fold-symmetric board, sees only
the tiles it owns and the ring of tiles touching them, and spends one move a
turn pushing armies outward.

Armies grow on cities and crowns every turn, and on **every owned tile every
25 turns** — land is production. Neutral cities hold 40 armies and are the
only toll on the board. And then the snowball: **capture another commander's
crown and you inherit every tile they own** — their land, their armies
(halved), their cities — and they are out. Last crown standing wins; if the
clock runs out first the ranking is survival, then land, then army, then
cities.

You always know, from the public standings, exactly how much land and army
each rival has. You never know **where** any of it is, or where their crown
is, until you walk a scout into their half and see it.

## A policy is just a prompt

Both champions are LLM prompt policies; both fillers are scripted baselines;
all four are the same image, switched by environment:

```bash
coworld upload-policy coworld-gen-generals-io:latest \
  --name my-generals --run /bin/gen-generals-io-player \
  --secret-env PLAYER_PROMPT="Land is the only thing that compounds..."
```

`PLAYER_SCRIPTED=sprawl` or `PLAYER_SCRIPTED=crown` seats a scripted baseline
instead. A seat that sets neither plays `sprawl`.

The LLM decides the **plan**, once every eight turns: an intent, a target
cell, a crown reserve, a city policy and how much of the next eight turns
goes to scouting. A deterministic captain compiles that plan into exactly one
legal move per turn, every turn, **from the seat's own fogged view** — and
the browser runs the identical Nim code, which is why the replay carries 120
plans rather than 960 moves.

## Watching it

The replay is a **static wasm bundle**, never a pod: `tools/build_replay_viewer.sh`
compiles the same `src/generals` sim modules to wasm through
`Dockerfile.replay-viewer` and bundles them with the starter's broadcast
chrome. The viewer re-simulates every turn in the browser and checks its
`gameHash` against the recording every tick.

The board draws edge to edge with the exact garrison integer on every
occupied cell, and a **fog lens** chip row lets a spectator watch the board as
any one commander saw it — a raid arriving out of the dark exactly as the
victim experienced it.

See [TRAINING.md](TRAINING.md) for native post-training exports.

## Layout

```
src/gen_generals_io.nim         the game server entrypoint
src/gen_generals_io_player.nim  the thin seat registrar
src/generals/                   the sim, the decision layer, the server
replay-viewer/gen_replay.nim    the wasm entry (same sim modules)
client/                         chrome_common.js + broadcast_core.js + the page
tools/                          the build hook, the CI harness, forensics
docs/RULES.md                   the rules, and the divergences from generals.io
docs/PROTOCOL.md                the wire protocol
docs/COMMANDING.md              how to write a plan prompt
```

## Building and testing

The sandbox has no Docker, no Nim and no emsdk: `ci.yml` is the harness.

```bash
nim r --path:src tests/tests.nim          # the sim, scoring, replay and manifest tests
./tools/ci/docker_smoke.sh coworld-gen-generals-io:ci
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
node tools/ci/viewer_smoke.mjs --bundle dist/static-replay-viewer \
  --replay dist/smoke/replay.json --timeout 90 --soak 10 --strict-text-bounds
```

Forked from [`Metta-AI/coworld-ctf`](https://github.com/Metta-AI/coworld-ctf)
(paintbot): the tick loop, the four-team seating and aliases, the decision
layer, the replay codec and the static wasm viewer are all its.
