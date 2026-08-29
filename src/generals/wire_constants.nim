## The one source of the constants the browser needs. `tools/gen_wire_constants.nim`
## prints this as `wire_constants.js` at bundle time, so a constant can never
## drift between the engine and the chrome.
##
## Two lines are emitted, not one:
##   window.GEN_WIRE={...};
##   window.CTF_WIRE=window.GEN_WIRE;
## The game's own code reads `GEN_WIRE`. The alias exists SOLELY so
## `client/chrome_common.js` — which this repo pins by sha256 against
## coworld-ctf (plus the fleet-wide 0.5x transport patch) and whose line 72
## reads `window.CTF_WIRE` — needs no wire-name edit.
## `Dockerfile.replay-viewer` asserts both lines.

import std/[json, strutils]
import sim_types, rig_art

proc wireConstants*(): JsonNode =
  var speeds = newJArray()
  # 0.5 is the replay-only half speed (ReplayHalfSpeed, command '5');
  # it rides ahead of the engine's integer PlaybackSpeeds.
  speeds.add(%0.5)
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
