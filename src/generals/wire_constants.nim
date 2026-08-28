## The one source of the constants the browser needs. `tools/gen_wire_constants.nim`
## prints this as `wire_constants.js` at bundle time, so a constant can never
## drift between the engine and the chrome.
##
## Two lines are emitted, not one:
##   window.GEN_WIRE={...};
##   window.CTF_WIRE=window.GEN_WIRE;
## The game's own code reads `GEN_WIRE`. The alias exists SOLELY so
## `client/chrome_common.js` — which this repo pins byte-for-byte against
## coworld-ctf and whose line 72 reads `window.CTF_WIRE` — needs no edit.
## `Dockerfile.replay-viewer` asserts both lines.

import std/[json, strutils]
import sim_types, rig_art

proc wireConstants*(): JsonNode =
  var speeds = newJArray()
  for speed in PlaybackSpeeds:
    speeds.add(%speed)
  %*{
    "speeds": speeds,
    "fps": ReplayFps,
    "chromeSpriteId": 4090,
    "game": GameName,
    "gameVersion": GameVersion,
    "protocol": ReplayProtocol,
    "cellPx": CellPx,
    "seats": Seats,
    "teams": ["red", "blue", "green", "yellow"],
    "aliases": [cogAlias(0), cogAlias(1), cogAlias(2), cogAlias(3)],
    "maxNoteRunes": MaxNoteRunes,
    "beatKinds": ["citytaken", "generalspotted", "generalcaptured", "end"]
  }

proc wireConstantsJs*(): string =
  "window.GEN_WIRE=" & $wireConstants() & ";\n" &
    "window.CTF_WIRE=window.GEN_WIRE;\n"
