## Dumps the chrome JSON one presentation frame carries, for every frame of a
## replay. `tools/ci/renderer_fixture.html` drives the SHIPPED page with these
## frames, so the fixture never re-implements the drawing (the
## particle-worlds 2026-08-26 scar) and the feed's commander-line path is
## exercised even though `docker_smoke.sh` runs with no ANTHROPIC_API_KEY and
## every seat in the CI replay therefore plays scripted.
##
##   nim r --path:src tools/dump_frames.nim <replay> [stride] > frames.json

import std/[json, os, strutils]
import generals/[broadcast, replay_runtime, replays, sim]

when isMainModule:
  if paramCount() < 1:
    quit("usage: dump_frames <replay path> [stride]", 2)
  let path = paramStr(1)
  let stride = if paramCount() >= 2: parseInt(paramStr(2)) else: 8
  let data = parseReplayBytes(readFile(path))
  var session = initReplaySession(data)
  var previousCells: seq[int] = @[]
  var frames = newJArray()
  var first = true
  while true:
    var beats: seq[JsonNode] = @[]
    for beat in session.player.beats:
      beats.add(beat)
    let context = FrameContext(
      tick: session.cursor, startTick: session.startTick,
      maxTick: session.endTick, playing: true, speed: 1,
      transportEnabled: true, mismatchTick: session.player.hashMismatchTick,
      lobbyCountdown: max(0, (session.startTick - session.cursor) div ReplayFps),
      lulls: session.player.lullSpans, beats: beats,
      lead: session.player.leadSeries,
      sendSeries: first or session.cursor <= session.startTick)
    frames.add(buildStateJson(session.sim, context, previousCells, first))
    first = false
    if session.cursor >= session.endTick:
      break
    session.seekTo(session.cursor + stride)
  echo $frames
