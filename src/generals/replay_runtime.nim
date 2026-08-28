## Replay playback: re-simulate the episode from the config plus the recorded
## plan input records, comparing `gameHash` against the recorded hash every
## tick. Forked from coworld-ctf's `src/ctf/replay_runtime.nim`.
##
## The browser runs THIS code: `replay-viewer/gen_replay.nim` compiles the
## same modules to wasm, which is why the replay carries plans rather than
## moves.

import std/[json, tables]
import sim_types, sim_config, sim_state, sim as gensim, replays

type
  ReplayPlayer* = object
    data*: ReplayData
    plansByTurn*: Table[int, seq[JsonNode]]
    stopTurn*: int
    maxTick*: int
    hashMismatchTick*: int
    playing*: bool
    speed*: int
    loop*: bool
    skipLulls*: bool
    seekTick*: int
    lullSpans*: seq[(int, int)]
    beats*: seq[JsonNode]
    leadSeries*: seq[seq[int]]
    names*: array[Seats, string]
    policyKinds*: array[Seats, string]
    planFeed*: seq[JsonNode]
    endTurn*: int

proc buildPlanTable(replay: ReplayData): Table[int, seq[JsonNode]] =
  result = initTable[int, seq[JsonNode]]()
  for record in replay.planRecords():
    let turn = record.payload{"turn"}.getInt()
    if not result.hasKey(turn):
      result[turn] = @[]
    result[turn].add(record.payload)

proc simFromReplay*(replay: ReplayData): Sim =
  var config = configFromJson(replay.config)
  config.tokens = @[]
  result = initSim(config)
  var seat = 0
  for record in replay.records:
    if record.kind == RecJoin and seat < Seats:
      let slot = record.payload{"slot"}.getInt(seat)
      if slot >= 0 and slot < Seats:
        result.names[slot] = record.payload{"name"}.getStr()
      seat.inc
  for record in replay.chatRecords("register"):
    let slot = record{"seat"}.getInt(-1)
    if slot >= 0 and slot < Seats:
      result.policyKinds[slot] = record{"kind"}.getStr("scripted")
      result.policies[slot] = record{"policy"}.getStr()

proc applyRecordedPlans*(sim: var Sim, player: ReplayPlayer) =
  if not player.plansByTurn.hasKey(sim.turn):
    return
  for node in player.plansByTurn[sim.turn]:
    let seat = node{"seat"}.getInt(-1)
    if seat < 0 or seat >= Seats:
      continue
    if not sim.stats[seat].alive:
      continue
    sim.installPlan(seat, planFromJson(node), psScripted, 0)

proc initReplayPlayer*(replay: ReplayData): ReplayPlayer =
  result.data = replay
  result.plansByTurn = buildPlanTable(replay)
  result.hashMismatchTick = -1
  result.playing = true
  result.speed = 1
  result.seekTick = -1
  result.stopTurn = -1
  result.endTurn = 0
  for record in replay.records:
    if record.kind == RecHash:
      result.maxTick = max(result.maxTick, record.tick)
  for node in replay.chatRecords("stop"):
    result.stopTurn = node{"turn"}.getInt(-1)
  for node in replay.chatRecords("plan"):
    result.planFeed.add(node)

proc prescan*(player: var ReplayPlayer) =
  ## The load-time pre-scan: re-simulate the whole episode once, headlessly,
  ## recording the per-turn land and army counts, the elimination turns, the
  ## lull spans and the beat turns, so the land-lead graph and the scrubber
  ## draw at FULL WIDTH on the first frame instead of growing in.
  var sim = simFromReplay(player.data)
  var lastBeat = 0
  var quietFrom = 0
  player.leadSeries = @[]
  player.beats = @[]
  player.lullSpans = @[]
  var spottedBeats = 0
  var cityBeats = 0
  while not sim.done and sim.turn < sim.config.maxTurns:
    if player.stopTurn >= 0 and sim.turn >= player.stopTurn:
      sim.applyWallClockStop(player.stopTurn)
      break
    sim.applyRecordedPlans(player)
    var row = @[sim.turn]
    for seat in 0 ..< Seats:
      row.add(sim.stats[seat].land)
    player.leadSeries.add(row)
    sim.stepTurn()
    var interesting = false
    for event in sim.frameEvents:
      let kind = event{"k"}.getStr()
      case kind
      of "citytaken":
        interesting = true
        if cityBeats < 16:
          cityBeats.inc
          player.beats.add(%*{"t": sim.turn, "k": "citytaken",
            "seat": event{"seat"}.getInt(-1)})
      of "generalspotted":
        interesting = true
        if spottedBeats < 12:
          spottedBeats.inc
          player.beats.add(%*{"t": sim.turn, "k": "generalspotted",
            "seat": event{"seat"}.getInt(-1)})
      of "generalcaptured":
        interesting = true
        player.beats.add(%*{"t": sim.turn, "k": "generalcaptured",
          "seat": event{"seat"}.getInt(-1)})
      of "growth":
        interesting = true
      else: discard
    if interesting:
      if sim.turn - quietFrom >= 30:
        player.lullSpans.add((quietFrom, sim.turn))
      quietFrom = sim.turn
      lastBeat = sim.turn
  player.endTurn = sim.turn
  player.beats.add(%*{"t": sim.turn, "k": "end"})
  ## The verdict rides the timeline as the starter's `gameover` beat, so
  ## chrome_common's own `setVerdict` lights the WINS chip and the scrubber
  ## cap without this game re-implementing either.
  let scores = sim.rankSeats(sim.turnsPlayed())
  let winner = winnerSeat(scores)
  const teamNames = ["red", "blue", "green", "yellow"]
  player.beats.add(%*{
    "t": sim.turn, "k": "gameover",
    "winner": (if winner >= 0: teamNames[winner] else: ""),
    "draw": winner < 0})
  discard lastBeat

proc stepReplay*(sim: var Sim, player: var ReplayPlayer) =
  ## One playback turn: install the recorded plans, step, and compare the
  ## hash. A single divergent bit is caught at the tick it happens.
  if sim.done:
    return
  if player.stopTurn >= 0 and sim.turn >= player.stopTurn:
    sim.applyWallClockStop(player.stopTurn)
    return
  sim.applyRecordedPlans(player)
  sim.stepTurn()
  let (recorded, found) = player.data.hashAt(sim.turn)
  if found and player.hashMismatchTick < 0 and recorded != sim.gameHash():
    player.hashMismatchTick = sim.turn

proc checkReplayHash*(sim: Sim, player: ReplayPlayer): bool =
  let (recorded, found) = player.data.hashAt(sim.turn)
  (not found) or recorded == sim.gameHash()

# ---- the playback session ----------------------------------------------

type
  ReplaySession* = object
    ## Everything a viewer needs to play the file: the sim, the recorded
    ## plans, the transport state and the presentation cursor. The browser
    ## and the native `/client/replay` server drive the identical object.
    sim*: Sim
    player*: ReplayPlayer
    cursor*: int            ## presentation tick, 0 .. maxTick
    startTick*: int
    endTick*: int
    playing*: bool
    speed*: int
    loop*: bool
    skipLulls*: bool
    fastForward*: bool

proc rebuild(session: var ReplaySession) =
  session.sim = simFromReplay(session.player.data)
  session.player.hashMismatchTick = -1

proc initReplaySession*(data: ReplayData): ReplaySession =
  result.player = initReplayPlayer(data)
  result.player.prescan()
  result.rebuild()
  result.startTick = result.sim.config.startWaitTicks
  result.endTick = result.startTick + result.player.endTurn +
    result.sim.config.gameOverTicks
  ## Playback OPENS at the game start, never in the recorded lobby: the
  ## prefix carries no board movement, and a runtime that walks it at
  ## presentation cadence sits frozen on its first tick until someone scrubs
  ## (cogame-pommerman / cogame-magent-battle, 2026-08-27). The hash-checked
  ## re-simulation below still runs every recorded frame from turn 0.
  result.cursor = result.startTick
  result.sim.phase = phPlaying
  result.playing = true
  result.speed = 1

proc turnAt(session: ReplaySession, cursor: int): int =
  clamp(cursor - session.startTick, 0, session.player.endTurn)

proc seekTo*(session: var ReplaySession, tick: int) =
  ## Backwards is a re-simulation from turn 0: 240 turns of integer work on
  ## 160 cells is under a millisecond, so a seek is instant and exact.
  ##
  ## EVERY seek is clamped to [startTick, endTick] — the restart control, the
  ## keyboard, a scrub click and the loop all land on the game start, matching
  ## the scrubber axis (`st`), which already skips the dead lobby.
  let target = clamp(tick, session.startTick, session.endTick)
  let wanted = session.turnAt(target)
  if wanted < session.sim.turn:
    session.rebuild()
  while session.sim.turn < wanted and not session.sim.done:
    session.sim.stepReplay(session.player)
  if session.player.stopTurn >= 0 and not session.sim.done and
      session.sim.turn >= session.player.stopTurn:
    ## The recorded wall-clock stop, applied by the SAME proc on record and
    ## on playback (the particle-worlds r2 scar).
    session.sim.applyWallClockStop(session.player.stopTurn)
  session.cursor = target
  ## Presentation phase: playing from the game start, gameover once the
  ## recorded episode has run out. The cursor can no longer reach the lobby
  ## prefix, so `phLobby` belongs to the live server alone.
  if session.sim.done or wanted >= session.player.endTurn:
    session.sim.phase = phGameOver
  else:
    session.sim.phase = phPlaying

proc applyCommand*(session: var ReplaySession, command: string) =
  ## The starter's transport vocabulary, unchanged.
  if command.len == 0:
    return
  case command[0]
  of ' ': session.playing = not session.playing
  of ',': session.seekTo(session.startTick)
  of 'b': session.seekTo(session.cursor - 1)
  of '.': session.seekTo(session.cursor + 5 * ReplayFps)
  of 'e': session.seekTo(session.endTick)
  of 'r': session.loop = not session.loop
  of 'f': session.skipLulls = not session.skipLulls
  of '+': session.speed = min(8, session.speed * 2)
  of '-': session.speed = max(1, session.speed div 2)
  of '1': session.speed = 1
  of '2': session.speed = 2
  of '4': session.speed = 4
  of '8': session.speed = 8
  of '6': session.speed = 8
  else: discard

proc inLull(session: ReplaySession, turn: int): bool =
  for span in session.player.lullSpans:
    if turn >= span[0] and turn < span[1]:
      return true
  false

proc advance*(session: var ReplaySession) =
  ## One presentation frame.
  session.fastForward = false
  if not session.playing:
    return
  var steps = max(1, session.speed)
  if session.skipLulls and session.inLull(session.turnAt(session.cursor)):
    steps = steps * 8
    session.fastForward = true
  for i in 0 ..< steps:
    if session.cursor >= session.endTick:
      if session.loop:
        session.seekTo(session.startTick)
      else:
        session.playing = false
      break
    session.seekTo(session.cursor + 1)
