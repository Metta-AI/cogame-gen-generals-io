## The gen-generals-io game server: the Coworld game contract over mummy.
##
## Forked from coworld-ctf's `src/ctf/server.nim` — the HTTP/websocket
## surface, `/healthz`, `/player?slot&token`, `/global`, `/client/*`,
## `/replay-data`, join/auth/kick, replay mode, the `COGAME_*` contract,
## `declarePlayerFailure`'s CLOSED payload, the artifact-write block, the
## `wallClockBudgetSeconds` stop and the bounded post-artifact shutdown grace.
##
## Four named edits (design note §Server):
##  1. the directive turn drives one PARALLEL batch every `directiveEvery`
##     turns and writes the structured plan as a replay INPUT record;
##  2. a player's Sprite v1 chat frame that parses as a registration object is
##     consumed as registration, held and re-read if the slot has not landed
##     yet, and written to the replay REDACTED (label and kind, never the
##     prompt). Any other chat text from a seat is dropped: this game has no
##     inter-seat channel;
##  3. the wall-clock stop writes the load-bearing `stop` record and is
##     applied on both sides by `sim.applyWallClockStop`;
##  4. the conquest end rule.

import std/[json, locks, os, sets, strutils, tables, times]
import bitworld/runtime
import bitworld/spriteprotocol
import mummy
import mummy/routers
import sim_types, sim_config, board, sim_state, sim as gensim, roster,
  replays, broadcast, global, llm, decide, events

const
  ShutdownGraceSeconds = 20.0
  PlayerProtocol* = "gen-generals-io.player.v1"

type
  ServerState = object
    prompts: seq[string]
    scripted: seq[ScriptKind]
    policies: seq[string]
    registered: seq[bool]
    everRegistered: seq[bool]
    heldRegistrations: Table[int, string]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    snapshot: seq[uint8]
    seats: int
    started: bool
    finished: bool

var
  stateLock: Lock
  shared: ServerState
  gameSim: Sim
  gameServer: Server
  boardArt: BoardArt
  viewerState: GlobalViewerState
  previousCells: seq[int]
  replayWriter: ReplayWriter
  replayPayload: string
  eventsSinkPath: string
  metricsSinkPath: string
  runtimeConfigGlobal: RuntimeConfig

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc frameContext(sim: Sim): FrameContext =
  FrameContext(
    tick: sim.config.startWaitTicks + sim.turn,
    startTick: sim.config.startWaitTicks,
    maxTick: sim.config.startWaitTicks + sim.config.maxTurns +
      sim.config.gameOverTicks,
    playing: true, speed: 1, transportEnabled: false, mismatchTick: -1,
    lobbyCountdown: 0, sendSeries: false)

proc refreshSnapshotLocked() =
  let chrome = buildStateJson(gameSim, frameContext(gameSim), previousCells,
    false)
  shared.snapshot = buildViewerPacket(gameSim, boardArt, viewerState, chrome)
  let blob = blobFromBytes(shared.snapshot)
  for socket in shared.globalSockets:
    try:
      socket.send(blob, BinaryMessage)
    except CatchableError:
      discard

proc declarePlayerFailure(slot: int, message: string) =
  ## The platform's CLOSED payload: exactly {"message","failed_policy_index"},
  ## for the lowest missing slot only. Best effort, a no-op off-platform.
  try:
    writeCogameEnv("COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot, "message": message}),
      "application/json")
  except CatchableError as error:
    echo "gen-generals-io: player-failure declaration failed: ", error.msg

proc requireFileUri(name: string): string =
  let uri = getEnv(name)
  if uri.len == 0:
    return ""
  if not uri.startsWith("file://"):
    raise newException(GenError, name & " must be a file:// path, got: " & uri)
  uri[7 .. ^1]

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  if uri.len == 0:
    return
  writeCogameUri(uri, data, contentType, methodEnv)

proc pushSeatFrames() =
  ## A seat frame carries NOTHING a seat may not know: its own alias, the
  ## turn, and whether it is still standing. No board, no rival, and never a
  ## real policy name — the two-name-space rule, asserted from both sides by
  ## `tests/test_gen_identity_privacy.nim`.
  for slot, socket in shared.playerSockets:
    if slot < 0 or slot >= Seats:
      continue
    try:
      socket.send($ %*{
        "type": "turn",
        "protocol": PlayerProtocol,
        "turn": gameSim.turn,
        "of": gameSim.config.maxTurns,
        "you": cogAlias(slot),
        "alive": gameSim.stats[slot].alive})
    except CatchableError:
      discard

proc broadcastDone(results: JsonNode) =
  ## Bounded: the artifacts matter more than a slow reader. An eliminated
  ## seat gets this frame like everyone else — elimination is a game state,
  ## not a disconnection.
  let payload = $ %*{"done": true, "result": results}
  var allowance = epochTime()
  for slot, socket in shared.playerSockets:
    allowance += 3.0
    if epochTime() > allowance:
      echo "gen-generals-io: done broadcast past its budget; skipping slot ",
        slot
      continue
    try:
      socket.send(payload)
    except CatchableError as error:
      echo "gen-generals-io: done frame to slot ", slot, " failed: ", error.msg

proc finishEpisode() =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if shared.finished:
      return
    shared.finished = true
    gameSim.endSummary()
    results = generalsResultsJson(gameSim)
    replayWriter.writeChat("result", results)
    replayData = replayWriter.bytes()
    replayPayload = replayData
    ## Final frames to the players BEFORE the artifacts: the hosted worker
    ## tears player pods down as soon as results.json exists.
    broadcastDone(results)
    refreshSnapshotLocked()
  echo "gen-generals-io: writing results and replay (", replayData.len,
    " bytes)"
  ## The REPLAY first, then the results: the worker treats results.json as
  ## the end of the episode.
  writeArtifact(runtimeConfigGlobal.replayUri, replayData,
    "application/octet-stream", "COGAME_SAVE_REPLAY_METHOD")
  writeArtifact(runtimeConfigGlobal.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD")
  if eventsSinkPath.len > 0:
    try:
      writeFile(eventsSinkPath, eventsJsonl(gameSim.events, gameSim.turn))
    except CatchableError as error:
      echo "gen-generals-io: event sink write failed: ", error.msg
  if metricsSinkPath.len > 0:
    try:
      writeFile(metricsSinkPath, $ %*{
        "turns": gameSim.turn,
        "events": gameSim.events.records.len,
        "reason": gameSim.reason,
        "endRule": gameSim.endRule})
    except CatchableError as error:
      echo "gen-generals-io: metrics sink write failed: ", error.msg
  echo "gen-generals-io: episode complete (", gameSim.reason, "/",
    gameSim.endRule, ") after ", gameSim.turn, " turns"

proc writePlanRecords(engine: DecideEngine, seats: seq[int],
    decisions: seq[Decision]) =
  for index, seat in seats:
    if index >= decisions.len:
      continue
    let decision = decisions[index]
    replayWriter.writePlanInput(gameSim.turn, seat, planJson(decision.plan))
    var record = %*{
      "turn": gameSim.turn, "seat": seat, "alias": cogAlias(seat),
      "source": $decision.source, "latency_ms": decision.latencyMs,
      "note": truncateRunes(decision.plan.note, MaxNoteRunes)}
    for key, value in planJson(decision.plan):
      record[key] = value
    replayWriter.writeChat("plan", record)
    gameSim.record(sePlan, %*{
      "seat": seat, "intent": $decision.plan.intent,
      "note": truncateRunes(decision.plan.note, MaxNoteRunes)})
  for fallback in engine.fallbacks:
    replayWriter.writeChat("fallback", fallback)
    gameSim.record(seFallback, fallback)
  engine.fallbacks = @[]

proc runGame() {.gcsafe.} =
  {.gcsafe.}:
    let config = gameSim.config
    let gameStart = epochTime()
    let connectDeadline = gameStart +
      float(config.lobbyJoinTimeoutTicks) / float(TargetFps)
    while epochTime() < connectDeadline:
      var allConnected = false
      withLock stateLock:
        allConnected = shared.playerSockets.len >= shared.seats
      if allConnected:
        break
      sleep(200)
    ## Give a connected-but-silent seat a moment to send its registration.
    let registerDeadline = min(epochTime() + 3.0, connectDeadline + 3.0)
    while epochTime() < registerDeadline:
      var allRegistered = true
      withLock stateLock:
        for slot in 0 ..< shared.seats:
          if shared.playerSockets.hasKey(slot) and not shared.registered[slot]:
            allRegistered = false
      if allRegistered:
        break
      sleep(100)

    var noShow = -1
    withLock stateLock:
      shared.started = true
      gameSim.phase = phPlaying
      gameSim.gameStartTick = config.startWaitTicks
      for slot in 0 ..< shared.seats:
        if not shared.everRegistered[slot]:
          if noShow < 0:
            noShow = slot
          ## A seat that never connects does not end the episode: it plays
          ## the sprawl baseline for the whole game.
          shared.scripted[slot] = skSprawl
          gameSim.stats[slot].dead = true
        let isLlm = shared.prompts[slot].strip().len > 0 and
          shared.scripted[slot] == skNone
        gameSim.policyKinds[slot] = if isLlm: "llm" else: "scripted"
        if shared.policies[slot].len > 0:
          gameSim.policies[slot] = shared.policies[slot]
        replayWriter.writeChat("register", %*{
          "seat": slot,
          "alias": cogAlias(slot),
          "policy": truncateRunes(shared.policies[slot],
            MaxPolicyLabelRunes),
          "kind": gameSim.policyKinds[slot],
          "baseline": $shared.scripted[slot]})
      echo "gen-generals-io: starting with ", shared.playerSockets.len, "/",
        shared.seats, " players connected"
      refreshSnapshotLocked()
    if noShow >= 0:
      declarePlayerFailure(noShow,
        "player slot " & $noShow & " never registered; the seat played the " &
        "sprawl baseline")

    let client = newLlmClient(config)
    let engine = newDecideEngine(client)
    withLock stateLock:
      for slot in 0 ..< shared.seats:
        let isLlm = gameSim.policyKinds[slot] == "llm"
        engine.setSeatPolicy(slot, isLlm, shared.prompts[slot],
          (if shared.scripted[slot] == skNone: skSprawl
           else: shared.scripted[slot]),
          connected = shared.playerSockets.hasKey(slot) or not isLlm)

    replayWriter.writeHash(gameSim.turn, gameSim.gameHash())
    while not gameSim.done:
      let elapsed = int(epochTime() - gameStart)
      ## 3. The wall-clock stop, checked at the top of every iteration and
      ## recorded as a load-bearing `stop` record.
      if elapsed > config.wallClockBudgetSeconds:
        replayWriter.writeChat("stop",
          %*{"turn": gameSim.turn, "endRule": "wall_clock"})
        gameSim.applyWallClockStop(gameSim.turn)
        break
      if gameSim.isDirectiveTurn():
        discard engine.considerBudgetGuard(gameSim, elapsed)
        if engine.budgetGuardTurn == gameSim.turn:
          replayWriter.writeChat("budget_guard", %*{
            "turn": gameSim.turn,
            "remaining_s": config.wallClockBudgetSeconds - elapsed})
        let seats = gameSim.aliveSeats()
        let decisions = engine.decideTurn(gameSim, seats, elapsed)
        engine.noteTurnBaseline(gameSim)
        for index, seat in seats:
          if index < decisions.len:
            gameSim.installPlan(seat, decisions[index].plan,
              decisions[index].source, decisions[index].latencyMs)
        writePlanRecords(engine, seats, decisions)
      try:
        gameSim.stepTurn()
      except GenGuardError as error:
        gameSim.stopDetail = truncateRunes(error.msg,
          MaxFallbackDetailRunes)
        echo "gen-generals-io: sim guard tripped: ", error.msg
        gameSim.finish("fault", "sim_fault")
      except CatchableError as error:
        gameSim.stopDetail = truncateRunes(error.msg,
          MaxFallbackDetailRunes)
        echo "gen-generals-io: host error during the step: ", error.msg
        gameSim.finish("fault", "host_error")
      replayWriter.writeHash(gameSim.turn, gameSim.gameHash())
      withLock stateLock:
        pushSeatFrames()
        refreshSnapshotLocked()
      if gameSim.turn mod 25 == 0:
        echo "gen-generals-io: turn ", gameSim.turn, "/", config.maxTurns,
          " alive ", gameSim.aliveCount(), " at ",
          int(epochTime() - gameStart), "s"

    finishEpisode()
    ## Keep /healthz and /global answering for a bounded grace after the
    ## artifacts are written (the lantern 0.1.3 scar), then exit.
    sleep(int(ShutdownGraceSeconds * 1000))
    quit(0)

var gameThread: Thread[void]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc replayPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "replay_broadcast.html",
      "text/html; charset=utf-8")

proc playerPageHandler(request: Request) {.gcsafe.} =
  ## Served for real and registered BEFORE any catch-all asset route, and it
  ## must NOT open the player socket (the lantern 0.1.1 cert probe).
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < gameSim.config.tokens.len and
        gameSim.config.tokens[slot] == token
    if slotText.len > 0 and not authorized:
      request.respond(403)
      return
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html; charset=utf-8"
    request.respond(200, headers,
      "<!doctype html><html><head><meta charset=\"utf-8\">" &
      "<title>gen-generals-io seat</title></head><body>" &
      "<h1>gen-generals-io</h1><p>Seat " & $slot &
      " is a view-only page: a policy is just a prompt, and every decision " &
      "is made in the game server.</p></body></html>")

proc globalPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let path = clientDir() / "replay_broadcast.html"
    if fileExists(path):
      serveFile(request, path, "text/html; charset=utf-8")
    else:
      var headers: HttpHeaders
      headers["Content-Type"] = "text/html; charset=utf-8"
      request.respond(200, headers,
        "<!doctype html><html><body>gen-generals-io spectator</body></html>")

proc clientAssetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".js"): "application/javascript; charset=utf-8"
      elif name.endsWith(".css"): "text/css; charset=utf-8"
      elif name.endsWith(".html"): "text/html; charset=utf-8"
      elif name.endsWith(".png"): "image/png"
      elif name.endsWith(".jpg"): "image/jpeg"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, clientDir() / name, contentType)

proc replayDataHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    if replayPayload.len == 0:
      request.respond(404)
      return
    var headers: HttpHeaders
    headers["Content-Type"] = "application/octet-stream"
    request.respond(200, headers, replayPayload)

proc rewardHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    var headers: HttpHeaders
    headers["Content-Type"] = "application/json"
    request.respond(200, headers, $ %*{"reward": 0.0})

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    var duplicate = false
    withLock stateLock:
      authorized = slot >= 0 and slot < gameSim.config.tokens.len and
        gameSim.config.tokens[slot] == token
      duplicate = authorized and shared.playerSockets.hasKey(slot)
    if not authorized:
      ## A wrong token must be REFUSED, not accepted (the flatland 0.1.1
      ## certifier probe).
      request.respond(403)
      return
    if duplicate:
      request.respond(409)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      shared.playerSockets[slot] = websocket
      shared.socketSlots[websocket] = slot
      echo "gen-generals-io: player slot ", slot, " connected (",
        shared.playerSockets.len, "/", shared.seats, ")"
      websocket.send($ %*{
        "type": "welcome", "protocol": PlayerProtocol, "slot": slot,
        "alias": cogAlias(slot),
        "turns": gameSim.config.maxTurns,
        "directive_every": gameSim.config.directiveEvery})

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      shared.globalSockets.incl(websocket)
      if shared.snapshot.len > 0:
        try:
          websocket.send(blobFromBytes(shared.snapshot), BinaryMessage)
        except CatchableError:
          discard

proc applyRegistration(slot: int, text: string): bool =
  ## Consumed as registration and NOT applied as a bubble and NOT written to
  ## the replay chat stream. Returns false when the text is not a
  ## registration object.
  var payload: JsonNode
  try:
    payload = parseJson(text)
  except CatchableError:
    return false
  if payload.kind != JObject or payload{"type"}.getStr() != "register":
    return false
  var prompt = payload{"prompt"}.getStr()
  prompt = truncateRunes(prompt, MaxPromptRunes)
  let node = payload{"scripted"}
  var scripted =
    if node == nil or node.kind == JNull: skNone
    else: parseScriptKind(node.getStr())
  if prompt.strip().len == 0 and scripted == skNone:
    scripted = skSprawl
  let policy = truncateRunes(payload{"policy"}.getStr(), MaxPolicyLabelRunes)
  withLock stateLock:
    shared.prompts[slot] = prompt
    shared.scripted[slot] = scripted
    shared.policies[slot] = policy
    shared.registered[slot] = true
    shared.everRegistered[slot] = true
  ## Loud on purpose: a seat whose register packet was lost plays the default
  ## baseline silently, which cost a whole episode once (grf-football r2).
  echo "gen-generals-io: slot ", slot, " registered policy=", policy,
    " kind=", (if scripted == skNone: "llm" else: "scripted " & $scripted),
    " prompt_chars=", prompt.len
  true

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
    message: Message) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application; the certifier pings
      ## /global, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      var slot = -1
      withLock stateLock:
        slot = shared.socketSlots.getOrDefault(websocket, -1)
      if message.kind == BinaryMessage:
        if slot >= 0:
          for item in parseSpriteClientMessages(message.data):
            if item.kind == SpriteClientChatMessage:
              if not applyRegistration(slot, item.text):
                ## Any other chat text from a seat is dropped: this game has
                ## no inter-seat channel of any kind.
                discard
        else:
          withLock stateLock:
            if websocket in shared.globalSockets:
              viewerState.applyGlobalViewerMessage(message.data)
        return
      if message.kind != TextMessage:
        return
      if slot < 0:
        return
      if not applyRegistration(slot, message.data):
        discard
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in shared.socketSlots:
          let slot = shared.socketSlots[websocket]
          shared.socketSlots.del(websocket)
          if shared.playerSockets.getOrDefault(slot) == websocket:
            shared.playerSockets.del(slot)
          ## A seat that drops keeps playing on sprawl and revives on
          ## reconnect.
          if shared.everRegistered[slot] and shared.prompts[slot].len > 0:
            shared.registered[slot] = false
        shared.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  ## The certifier's browser probes are registered BEFORE any catch-all
  ## asset route.
  result.get("/healthz", healthzHandler)
  result.get("/client/player", playerPageHandler)
  result.get("/client/global", globalPageHandler)
  result.get("/client/replay", replayPageHandler)
  result.get("/client/@name", clientAssetHandler)
  result.get("/replay-data", replayDataHandler)
  result.get("/reward", rewardHandler)
  result.get("/global", globalUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  replayPayload = runtimeConfig.replay
  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  echo "gen-generals-io: replay mode on ", runtimeConfig.host, ":",
    runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc stopServer*() =
  if gameServer != nil:
    gameServer.close()

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.numAgents:
    raise newException(GenError, "tokens must name exactly num_agents seats")
  runtimeConfigGlobal = runtimeConfig
  eventsSinkPath = requireFileUri("COGAME_EVENTS_URI")
  metricsSinkPath = requireFileUri("COGAME_METRICS_URI")
  let bakeStart = epochTime()
  gameSim = initSim(config)
  boardArt = bakeBoardArt(gameSim)
  viewerState = initGlobalViewerState()
  replayWriter = initReplayWriter(config.configJson())
  for seat in 0 ..< Seats:
    replayWriter.writeJoin(seat, gameSim.names[seat], "")
  echo "gen-generals-io: board baked in ",
    int((epochTime() - bakeStart) * 1000.0), " ms (",
    gameSim.board.w, "x", gameSim.board.h, ", ",
    gameSim.board.countKind(ckMountain), " mountains, ",
    gameSim.board.countKind(ckCity), " cities)"
  shared.seats = config.numAgents
  shared.prompts = newSeq[string](shared.seats)
  shared.scripted = newSeq[ScriptKind](shared.seats)
  shared.policies = newSeq[string](shared.seats)
  shared.registered = newSeq[bool](shared.seats)
  shared.everRegistered = newSeq[bool](shared.seats)
  shared.heldRegistrations = initTable[int, string]()
  let chrome = buildStateJson(gameSim, frameContext(gameSim), previousCells,
    true)
  shared.snapshot = buildViewerPacket(gameSim, boardArt, viewerState, chrome)

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  createThread(gameThread, runGame)
  echo "gen-generals-io: serving on ", runtimeConfig.host, ":",
    runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
