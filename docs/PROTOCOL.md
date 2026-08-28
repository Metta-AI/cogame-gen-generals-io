# Wire protocol

## The Coworld runtime contract

In: `COGAME_CONFIG_URI`. Out: `COGAME_RESULTS_URI`, `COGAME_SAVE_REPLAY_URI`,
`COGAME_PLAYER_FAILURE_URI`, `COGAME_EVENTS_URI`, `COGAME_METRICS_URI`.
`COGAME_LOAD_REPLAY_URI` + `/client/replay` drive local replay mode.
`COGAME_HOST` / `COGAME_PORT` bind the server.

HTTP: `GET /healthz`, `GET /client/player?slot=&token=` (token-checked, and it
does **not** open the player socket), `GET /client/global`,
`GET /client/replay`, `GET /client/<asset>`, `GET /replay-data`,
`GET /reward`. Websockets: `/player?slot=<i>&token=<t>` (403 on a bad slot or
token, 409 on a duplicate) and `/global`.

## The player socket

A seat sends **one Sprite v1 chat frame** (`0x81`) carrying its registration,
re-sent ten times over the first ten seconds because joins are
slot-sequential:

```json
{"type":"register","policy":"<label, <=48 runes>",
 "prompt":"<PLAYER_PROMPT or empty, <=4000 runes>",
 "scripted":"sprawl"|"crown"|null}
```

A seat that registers with neither field, or never registers, is seated as
`sprawl`. Any OTHER chat text from a seat is dropped: this game has no
inter-seat channel of any kind — no chat, no radio, no `say`, no emote.

The seat then sends the Sprite v1 Ready packet (`0x85`) after each received
frame, which is legitimate here because **a seat sends no inputs**: every
decision is made in the game server, which calls the LLM once every eight
turns with all living seats batched into ONE parallel request.

The game sends the seat:

```json
{"type":"welcome","protocol":"gen-generals-io.player.v1","slot":0,
 "alias":"RED-alpha","turns":240,"directive_every":8}
{"type":"turn","turn":96,"of":240,"you":"RED-alpha","alive":true}
{"done":true,"result":{...the results document...}}
```

A seat frame carries **nothing a seat may not know**: its own alias, the turn
and whether it is still standing. No board, no rival, and never a real policy
name. An eliminated seat keeps receiving frames and exits 0 with everyone
else — elimination is a game state, not a disconnection.

## The spectator socket

`/global` speaks the Sprite v1 binary protocol: sprite definitions, object
placements, a viewport and a layer, exactly as `client/broadcast_core.js`
decodes them. The broadcast chrome rides as the LABEL of the reserved 1 × 1
sprite id 4090, which is what makes it survive a hosted replay.

One chrome object per presentation frame. The inherited keys (`t`, `mt`,
`ph`, `lob`, `sp`, `mx`, `st`, `lp`, `sk`, `ff`, `en`, `mm`, `teams`,
`roster`, `events`, `lead`, `lulls`, `beats`, `over`) are the starter's;
gen-generals-io adds:

```json
{"turn": 96, "turns": 240, "growthIn": 4, "growthEvery": 25,
 "w": 16, "h": 10,
 "cells": [{"i": 37, "k": "plain", "o": 0, "a": 54}],
 "gen":   [17, 28, -1, 142],
 "alive": [true, true, false, true],
 "stand": {"land": [31,27,0,34], "army": [210,188,0,156], "cities": [1,2,0,0]},
 "out":   [-1, -1, 71, -1],
 "outBy": [-1, -1, 1, -1],
 "plan":  [{"seat": 0, "turn": 96, "intent": "expand", "source": "llm",
            "note": "taking the middle before blue does"}]}
```

`cells` is a **delta** (the full array on the first frame and on every
keyframe); `i` is a cell index and `o` a seat index or `-1` for neutral.
`gen[s]` is seat `s`'s crown cell, or `-1` once captured. **The per-seat fog
is NOT transmitted**: the viewer derives `visible[s] = owned ∪
8-neighbours(owned)` in the browser exactly as the sim does, which costs zero
replay bytes and cannot drift.

## Derived events — a closed enum of twelve kinds

`phase`, `growth`, `claim`, `citytaken`, `tilelost`, `stackclash`,
`generalspotted`, `generalcaptured`, `eliminated`, `plan`, `fallback`, `end`.

**Beats** — the scrubber markers, and the only kinds the game block draws:
`citytaken`, `generalspotted`, `generalcaptured`, `end`. Each is a labelled,
clickable button that seeks on click.

## The replay

Binary, magic `COWLDGEN`:

```
"COWLDGEN" | u16 formatVersion | u16 len + game name | u16 len + game version
           | u32 len + the resolved config JSON
           | records: u8 kind, u32 length, payload
```

Record kinds: `1` join, `2` **plan input** (load-bearing, re-applied before
the turn it belongs to is stepped), `3` chat (`register` / `plan` /
`fallback` / `budget_guard` / `stop` / `result`), `4` hash (u32 turn, u32
`gameHash`), `5` leave.

The board is **re-derived from the seed** rather than stored — it is in
`gameHash` from turn 0, so a divergence surfaces immediately. Everything the
viewer needs is in the bytes; no server is contacted except S3 for the file.
`tools/replay_summary.py` (Python 3 stdlib only) prints one strict-UTF-8 JSON
object describing a replay.
