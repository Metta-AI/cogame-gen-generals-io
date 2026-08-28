## The wasm replay entry. Compiled by `tools/build_replay_viewer.sh` through
## `Dockerfile.replay-viewer`'s pinned emscripten/emsdk + nimby container,
## against the SAME `src/generals` sim modules the server runs — which is why
## the replay carries 120 plans rather than 960 moves.
##
## Structure kept exactly from coworld-ctf's replay-viewer entry point:
## the `stampStage` fixed progress buffer that survives an allocation abort,
## `bytesFromPointer`, the try/except publishing `lastError`, and the
## `emscripten_exit_with_live_runtime()` epilogue that stops Nim's generated
## `main` from running module destructors while JS keeps calling in.
##
## Two additions (design note §Viewer):
##  - a load-time PRE-SCAN, so the land-lead graph and the scrubber beats draw
##    at full width on the first frame instead of growing in;
##  - `gen_mismatch_tick`, the divergence tick or -1.

import
  std/json,
  generals/[broadcast, global, replay_runtime, replays, sim]

var
  runtimeLoaded = false
  session: ReplaySession
  art: BoardArt
  viewer: GlobalViewerState
  previousCells: seq[int]
  packet: seq[uint8]
  lastError: string
  firstFrame = true

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals instead of trapping. The bundle is therefore linked
## with -s ABORTING_MALLOC=1 and this fixed buffer, stamped BEFORE each risky
## phase, stays readable from JS after the abort.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc frameContextOf(): FrameContext =
  var beats: seq[JsonNode] = @[]
  for beat in session.player.beats:
    beats.add(beat)
  FrameContext(
    tick: session.cursor,
    startTick: session.startTick,
    maxTick: session.endTick,
    playing: session.playing,
    speed: session.speed,
    loop: session.loop,
    skipLulls: session.skipLulls,
    fastForward: session.fastForward,
    transportEnabled: true,
    mismatchTick: session.player.hashMismatchTick,
    # Playback opens at the game start and no seek can reach the lobby prefix
    # (`replay_runtime.seekTo`), so the curtain never counts down on a replay.
    lobbyCountdown: 0,
    lulls: session.player.lullSpans,
    beats: beats,
    lead: session.player.leadSeries,
    # The pre-scan series rides every LOBBY frame, not only the first: the
    # appended game block is a later <script> in the same document, so a
    # first frame that landed before it parsed would otherwise take the beat
    # timeline with it.
    sendSeries: firstFrame or session.cursor <= session.startTick)

proc renderCurrent() =
  let chrome = buildStateJson(session.sim, frameContextOf(), previousCells,
    firstFrame)
  packet = buildViewerPacket(session.sim, art, viewer, chrome)
  firstFrame = false

proc genLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "gen_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    let replayData = parseReplayBytes(data.bytesFromPointer(int(length)))
    stampStage("initialize replay runtime")
    session = initReplaySession(replayData)
    stampStage("bake the board")
    art = bakeBoardArt(session.sim)
    viewer = initGlobalViewerState()
    previousCells = @[]
    firstFrame = true
    runtimeLoaded = true
    frameStage = "advance replay (" & $session.sim.board.w & "x" &
      $session.sim.board.h & ")"
    stampStage("render first frame")
    renderCurrent()
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc genInput(data: ptr uint8, length: cint)
    {.exportc: "gen_input", cdecl.} =
  if runtimeLoaded:
    viewer.applyGlobalViewerMessage(data.bytesFromPointer(int(length)))

proc genFrame(): cint {.exportc: "gen_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage(frameStage)
  try:
    if viewer.replaySeekTick >= 0:
      session.seekTo(viewer.replaySeekTick)
      viewer.replaySeekTick = -1
    for command in viewer.replayCommands:
      session.applyCommand(command)
    viewer.replayCommands = @[]
    session.advance()
    renderCurrent()
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg & "\n" & error.getStackTrace()
    return -1

proc genPacketPointer(): ptr uint8 {.exportc: "gen_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: packet[0].addr

proc genPacketLength(): cint {.exportc: "gen_packet_len", cdecl.} =
  cint(packet.len)

proc genMismatchTick(): cint {.exportc: "gen_mismatch_tick", cdecl.} =
  if runtimeLoaded: cint(session.player.hashMismatchTick) else: -1

proc genErrorPointer(): ptr uint8 {.exportc: "gen_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc genErrorLength(): cint {.exportc: "gen_error_len", cdecl.} =
  cint(lastError.len)

proc genStagePointer(): ptr uint8 {.exportc: "gen_stage_ptr", cdecl.} =
  ## Unlike gen_error_*, this stays valid after an allocation-failure abort,
  ## so the page can still report what the runtime was doing.
  if stageNoteLen == 0: nil else: cast[ptr uint8](stageNote[0].addr)

proc genStageLength(): cint {.exportc: "gen_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing the baked board, the fonts and the replay — everything — while
  # the wasm module stays alive and JS keeps calling gen_load_replay /
  # gen_frame. Unwinding main through emscripten's live-runtime exit skips
  # the destructor epilogue entirely, so globals stay valid for the life of
  # the page.
  emscriptenExitWithLiveRuntime()
