## The mutable world: the `Sim` object, its construction, the per-tick
## `gameHash` chain, the sim guard and the small queries every other module
## needs. Forked from coworld-ctf's `src/ctf/sim_state.nim`.

import std/[json]
import sim_types, sim_config, board, vision, events

type
  Phase* = enum
    phLobby = "lobby"
    phPlaying = "playing"
    phGameOver = "gameover"

  SeatStats* = object
    alive*: bool
    eliminatedTurn*: int
    eliminatedBy*: int
    land*: int
    army*: int64
    cities*: int
    generalsCaptured*: int
    tilesTaken*: int64
    tilesLost*: int64
    movesMade*: int64
    invalidMoves*: int
    passes*: int
    landInherited*: int
    armyInherited*: int64
    llmTurns*: int
    fallbackTurns*: int
    directivesRejected*: int
    dead*: bool

  Sim* = object
    config*: GameConfig
    board*: Board
    memory*: array[Seats, Memory]
    visible*: array[Seats, seq[bool]]
    stats*: array[Seats, SeatStats]
    plan*: array[Seats, Plan]
    planSource*: array[Seats, PlanSource]
    planLatency*: array[Seats, int]
    planTurn*: array[Seats, int]
    havePlan*: array[Seats, bool]
    spotted*: array[Seats, array[Seats, bool]]
    mission*: array[Seats, MissionState]
    names*: array[Seats, string]
    policies*: array[Seats, string]
    policyKinds*: array[Seats, string]
    turn*: int
    tick*: int
    lobbyTicks*: int
    gameStartTick*: int
    phase*: Phase
    done*: bool
    reason*: string
    endRule*: string
    stopDetail*: string
    events*: EventBuffer
    frameEvents*: JsonNode      ## the events derived for THIS tick
    connected*: array[Seats, bool]
    wallClockStopTurn*: int

  MissionKind* = enum
    mkNone, mkExpand, mkGather, mkAttack, mkDefend, mkScout, mkRaid, mkCity

  MissionState* = object
    kind*: MissionKind
    source*: int
    goal*: int
    stepsLeft*: int
    active*: bool

const
  LegalReasons* = ["complete", "deadline", "fault"]
  LegalEndRules* = ["conquest", "full_time", "wall_clock", "sim_fault",
    "host_error"]

proc recomputeVision*(sim: var Sim) =
  for seat in 0 ..< Seats:
    if sim.stats[seat].alive:
      sim.visible[seat] = visibleSet(sim.board, seat)
    else:
      sim.visible[seat] = newSeq[bool](sim.board.cellCount())

proc recountSeats*(sim: var Sim) =
  for seat in 0 ..< Seats:
    sim.stats[seat].land = 0
    sim.stats[seat].army = 0
    sim.stats[seat].cities = 0
  for cell in 0 ..< sim.board.cellCount():
    let owner = sim.board.ownerOf(cell)
    if owner < 0:
      continue
    sim.stats[owner].land.inc
    sim.stats[owner].army += int64(sim.board.armyOf(cell))
    if sim.board.kindOf(cell) == ckCity:
      sim.stats[owner].cities.inc

proc initSim*(config: GameConfig): Sim =
  var cfg = config
  cfg.validate()
  result.config = cfg
  result.board = generateBoard(cfg)
  result.turn = 0
  result.tick = 0
  result.phase = phLobby
  result.reason = ""
  result.endRule = ""
  result.stopDetail = ""
  result.wallClockStopTurn = -1
  result.frameEvents = newJArray()
  for seat in 0 ..< Seats:
    result.memory[seat] = initMemory(result.board.cellCount())
    result.visible[seat] = newSeq[bool](result.board.cellCount())
    result.stats[seat] = SeatStats(
      alive: true, eliminatedTurn: -1, eliminatedBy: -1)
    result.plan[seat] = defaultPlanValue()
    result.planSource[seat] = psScripted
    result.planTurn[seat] = -1
    result.names[seat] = "seat-" & $seat
    result.policies[seat] = ""
    result.policyKinds[seat] = "scripted"
  if cfg.players.len == Seats:
    for seat in 0 ..< Seats:
      let name = cfg.players[seat].name
      if name.len > 0:
        result.names[seat] = runeCap(name, MaxPolicyLabelRunes)
  result.recountSeats()
  result.recomputeVision()
  for seat in 0 ..< Seats:
    result.memory[seat].rememberVisible(result.board, result.visible[seat], 0)

proc aliveSeats*(sim: Sim): seq[int] =
  for seat in 0 ..< Seats:
    if sim.stats[seat].alive:
      result.add(seat)

proc aliveCount*(sim: Sim): int =
  for seat in 0 ..< Seats:
    if sim.stats[seat].alive:
      result.inc

proc gameTicksElapsed*(sim: Sim): int =
  max(0, sim.tick - sim.gameStartTick)

proc record*(sim: var Sim, kind: SimEventKind, fields: JsonNode) =
  sim.events.emit(sim.turn, kind, fields)
  var node = newJObject()
  node["k"] = %($kind)
  node["t"] = %sim.turn
  for key, value in fields:
    node[key] = value
  sim.frameEvents.add(node)

# ---- hash ---------------------------------------------------------------

proc mixHash*(hash: var uint32, value: int) {.inline.} =
  let v = cast[uint32](int32(value))
  for shift in [0, 8, 16, 24]:
    hash = hash xor ((v shr uint32(shift)) and 0xFF'u32)
    hash = hash * 16777619'u32

proc planHashFields*(plan: Plan): array[6, int] =
  [ord(plan.intent),
   (if plan.hasTarget: 1 else: 0),
   plan.targetX, plan.targetY,
   plan.reserve * 8 + ord(plan.cities),
   plan.scouts]

proc gameHash*(sim: Sim): uint32 =
  ## Mixed in this fixed order: turn; per cell (kind, owner, army); per seat
  ## the counters; per seat the fog memory digest; per seat the structured
  ## plan. The note, the source, the latency and every policy label are
  ## EXCLUDED - nothing a commander SAYS may move the hash chain.
  var hash = 2166136261'u32
  hash.mixHash(sim.turn)
  for cell in 0 ..< sim.board.cellCount():
    hash.mixHash(int(sim.board.kind[cell]))
    hash.mixHash(int(sim.board.owner[cell]))
    hash.mixHash(int(sim.board.army[cell]))
  for seat in 0 ..< Seats:
    let stat = sim.stats[seat]
    hash.mixHash(if stat.alive: 1 else: 0)
    hash.mixHash(stat.eliminatedTurn)
    hash.mixHash(stat.eliminatedBy)
    hash.mixHash(stat.land)
    hash.mixHash(int(stat.army and 0x7FFFFFFF))
    hash.mixHash(stat.cities)
    hash.mixHash(stat.generalsCaptured)
    hash.mixHash(int(stat.tilesTaken and 0x7FFFFFFF))
    hash.mixHash(int(stat.tilesLost and 0x7FFFFFFF))
    hash.mixHash(int(stat.movesMade and 0x7FFFFFFF))
    hash.mixHash(stat.invalidMoves)
    hash.mixHash(stat.passes)
  for seat in 0 ..< Seats:
    let (count, mixed) = sim.memory[seat].memoryDigest()
    hash.mixHash(count)
    hash.mixHash(mixed)
  for seat in 0 ..< Seats:
    for field in planHashFields(sim.plan[seat]):
      hash.mixHash(field)
  hash

# ---- guard --------------------------------------------------------------

proc checkGeneralsInvariants*(sim: Sim) =
  ## Evaluated every turn. A trip raises GenGuardError -> fault / sim_fault.
  template fail(msg: string) =
    raise newException(GenGuardError, msg)

  var land: array[Seats, int]
  var army: array[Seats, int64]
  var cities: array[Seats, int]
  var generals: array[Seats, int]
  for seat in 0 ..< Seats:
    generals[seat] = 0
  for cell in 0 ..< sim.board.cellCount():
    let kind = sim.board.kindOf(cell)
    let owner = sim.board.ownerOf(cell)
    let armyHere = sim.board.armyOf(cell)
    if armyHere < 0 or armyHere > MaxCellArmy:
      fail("cell " & $cell & " army out of range: " & $armyHere)
    if kind == ckMountain and (owner != -1 or armyHere != 0):
      fail("mountain " & $cell & " is owned or garrisoned")
    if owner == -1 and kind == ckPlain and armyHere != 0:
      fail("neutral plain " & $cell & " holds " & $armyHere & " army")
    if owner >= 0:
      land[owner].inc
      army[owner] += int64(armyHere)
      if kind == ckCity:
        cities[owner].inc
      if kind == ckGeneral:
        generals[owner].inc
        if sim.board.generalCell[owner] != cell:
          fail("seat " & $owner & " general cell drifted")
  var total = 0
  for seat in 0 ..< Seats:
    total += land[seat]
    if sim.stats[seat].alive:
      if generals[seat] != 1:
        fail("living seat " & $seat & " owns " & $generals[seat] & " generals")
    else:
      if land[seat] != 0:
        fail("dead seat " & $seat & " still owns " & $land[seat] & " cells")
    if land[seat] != sim.stats[seat].land:
      fail("seat " & $seat & " land bookkeeping drifted")
    if army[seat] != sim.stats[seat].army:
      fail("seat " & $seat & " army bookkeeping drifted")
    if cities[seat] != sim.stats[seat].cities:
      fail("seat " & $seat & " city bookkeeping drifted")
    if not sim.stats[seat].alive:
      continue
    for cell in 0 ..< sim.board.cellCount():
      if sim.visible[seat][cell] and sim.memory[seat].seenTurn[cell] < 0:
        fail("seat " & $seat & " sees an unremembered cell")
  if total > sim.board.cellCount():
    fail("owned cells exceed the board")
  if sim.turn > sim.config.maxTurns:
    fail("turn " & $sim.turn & " past maxTurns")
  if not sim.board.mountainSymmetric():
    fail("the mountain layout stopped being four-fold symmetric")

proc applyWallClockStop*(sim: var Sim, turn: int) =
  ## The wall-clock stop is a wall-clock FACT no re-simulation can derive, so
  ## it is recorded once and applied by THIS proc on both sides (the
  ## particle-worlds r2 scar).
  sim.wallClockStopTurn = turn
  sim.done = true
  sim.phase = phGameOver
  sim.reason = "deadline"
  sim.endRule = "wall_clock"

proc finish*(sim: var Sim, reason, endRule: string) =
  if sim.done:
    return
  sim.done = true
  sim.phase = phGameOver
  sim.reason = reason
  sim.endRule = endRule
