## Tests 8-11 — the captain never emits an illegal move, is blind outside the
## fog, is a pure function, and shares its fallback with the sprawl baseline.

import std/[unittest, random]
import generals/sim as gensim

proc scriptedSim(seed: int): Sim =
  var config = defaultGameConfig()
  config.seed = seed
  config.players = @[]
  for seat in 0 ..< Seats:
    config.players.add(PlayerConfig(name: "seat-" & $seat))
  gensim.initSim(config)

proc randomPlan(rng: var Rand, view: SeatView): Plan =
  result = Plan(
    intent: Intent(rng.rand(ord(high(Intent)))),
    hasTarget: rng.rand(1) == 1,
    targetX: rng.rand(view.w - 1),
    targetY: rng.rand(view.h - 1),
    reserve: rng.rand(999),
    cities: CityPolicy(rng.rand(ord(high(CityPolicy)))),
    scouts: rng.rand(3),
    note: "")

proc garbleOutsideFog(view: SeatView, rng: var Rand): SeatView =
  ## Every cell outside `visible ∪ remembered` replaced by garbage. The
  ## captain must not notice.
  result = view
  for cell in 0 ..< view.viewCells():
    if view.isVisible(cell) or view.isRemembered(cell):
      continue
    result.kindNow[cell] = int8(rng.rand(ord(high(CellKind))))
    result.ownerNow[cell] = int8(rng.rand(Seats) - 1)
    result.armyNow[cell] = int32(rng.rand(500))
    result.kindSeen[cell] = int8(rng.rand(ord(high(CellKind))))
    result.ownerSeen[cell] = int8(rng.rand(Seats) - 1)

suite "the captain":
  test "it never emits an illegal move, over 300 states and both baselines":
    var rng = initRand(4242)
    var checked = 0
    for seed in 0 ..< 30:
      var sim = scriptedSim(1000 + seed)
      for turn in 0 ..< 120:
        if sim.done:
          break
        if sim.isDirectiveTurn():
          for seat in sim.aliveSeats():
            let view = sim.viewOf(seat)
            let kind = if (seat + seed) mod 2 == 0: skSprawl else: skCrown
            sim.installPlan(seat, scriptedPlan(view, kind), psScripted, 0)
        for seat in 0 ..< Seats:
          if not sim.stats[seat].alive:
            continue
          let view = sim.viewOf(seat)
          var mission = sim.mission[seat]
          let (move, emitted) = compileMove(view, sim.plan[seat], seat,
            mission, sim.config)
          if not emitted:
            continue
          checked.inc
          check view.ownsCell(move.fromCell)
          check view.knownArmy(move.fromCell) >= 2
          check move.amount >= 1
          check move.amount <= view.knownArmy(move.fromCell) - 1
          let (dx, dy) = dirDelta(move.dir)
          let tx = view.viewX(move.fromCell) + dx
          let ty = view.viewY(move.fromCell) + dy
          check view.onView(tx, ty)
          check not view.knownMountain(view.cellIndexOf(tx, ty))
        sim.stepTurn()
    check checked > 500
    discard rng

  test "a random but VALID plan never produces an illegal move either":
    var rng = initRand(99)
    var sim = scriptedSim(7)
    var emitted = 0
    for turn in 0 ..< 200:
      if sim.done:
        break
      for seat in sim.aliveSeats():
        let view = sim.viewOf(seat)
        let plan = clampPlan(randomPlan(rng, view), view.w, view.h)
        var mission = sim.mission[seat]
        let (move, ok) = compileMove(view, plan, seat, mission, sim.config)
        if not ok:
          continue
        emitted.inc
        check view.ownsCell(move.fromCell)
        check move.amount >= 1
        check move.amount <= view.knownArmy(move.fromCell) - 1
      sim.stepTurn()
    check emitted > 100

  test "a dead seat never gets a move, and a boxed-in seat passes":
    var sim = scriptedSim(11)
    sim.stats[1].alive = false
    for cell in 0 ..< sim.board.cellCount():
      if sim.board.ownerOf(cell) == 1:
        sim.board.owner[cell] = NoOwner
        sim.board.army[cell] = 0
    sim.board.generalCell[1] = -1
    sim.recountSeats()
    sim.recomputeVision()
    let (_, hasMove) = sim.compileMoves()
    check not hasMove[1]
    ## Every tile at one army: nothing legal, so the seat passes rather than
    ## stalling.
    var boxed = scriptedSim(12)
    for cell in 0 ..< boxed.board.cellCount():
      if boxed.board.ownerOf(cell) >= 0:
        boxed.board.army[cell] = 1
    boxed.recountSeats()
    let passesBefore = boxed.stats[0].passes
    let (_, boxedMoves) = boxed.compileMoves()
    check not boxedMoves[0]
    check boxed.stats[0].passes == passesBefore + 1

  test "the captain is BLIND outside the fog":
    var rng = initRand(31337)
    var sim = scriptedSim(21)
    var compared = 0
    for turn in 0 ..< 160:
      if sim.done:
        break
      if sim.isDirectiveTurn():
        for seat in sim.aliveSeats():
          let view = sim.viewOf(seat)
          let kind = if seat mod 2 == 0: skSprawl else: skCrown
          sim.installPlan(seat, scriptedPlan(view, kind), psScripted, 0)
      for seat in sim.aliveSeats():
        let view = sim.viewOf(seat)
        let garbled = garbleOutsideFog(view, rng)
        for trial in 0 ..< 3:
          let plan =
            if trial == 0: sim.plan[seat]
            else: clampPlan(randomPlan(rng, view), view.w, view.h)
          var missionA = sim.mission[seat]
          var missionB = sim.mission[seat]
          let (moveA, okA) = compileMove(view, plan, seat, missionA,
            sim.config)
          let (moveB, okB) = compileMove(garbled, plan, seat, missionB,
            sim.config)
          check okA == okB
          if okA:
            compared.inc
            check moveA.fromCell == moveB.fromCell
            check moveA.dir == moveB.dir
            check moveA.amount == moveB.amount
      sim.stepTurn()
    check compared > 200

  test "the captain is a pure function of (view, plan, seat)":
    var sim = scriptedSim(5)
    for turn in 0 ..< 40:
      sim.stepTurn()
    for seat in sim.aliveSeats():
      let view = sim.viewOf(seat)
      let plan = sprawlPlan(view)
      var first = MissionState()
      var second = MissionState()
      let (moveA, okA) = compileMove(view, plan, seat, first, sim.config)
      let (moveB, okB) = compileMove(view, plan, seat, second, sim.config)
      check okA == okB
      check moveA == moveB
      check first == second

  test "the server-side fallback IS the sprawl baseline proc":
    var sim = scriptedSim(77)
    for turn in 0 ..< 24:
      sim.stepTurn()
    for seat in sim.aliveSeats():
      let view = sim.viewOf(seat)
      check fallbackPlan(view) == sprawlPlan(view)
      check scriptedPlan(view, skSprawl) == sprawlPlan(view)
