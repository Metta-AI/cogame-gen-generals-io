## Tests 7, 12, 13 — bounded orders from both baselines, the head-to-head, and
## the swept tuning pick.

import std/[unittest, json, random, os, strutils]
import generals/sim as gensim
import generals/roster

proc episodeSim(seed: int, boardW = 16, boardH = 10): Sim =
  var config = defaultGameConfig()
  config.seed = seed
  config.boardW = boardW
  config.boardH = boardH
  if boardW == 12:
    config.mountainPct = 18
    config.cityCount = 4
    config.maxTurns = 160
    config.growthPeriod = 15
  config.players = @[]
  for seat in 0 ..< Seats:
    config.players.add(PlayerConfig(name: "seat-" & $seat))
  gensim.initSim(config)

suite "the scripted baselines are bounded":
  test "300 world states x both baselines stay inside the reply schema":
    var rng = initRand(2026)
    var states = 0
    for seed in 0 ..< 20:
      let boardW = if seed mod 2 == 0: 16 else: 12
      let boardH = if seed mod 2 == 0: 10 else: 8
      var sim = episodeSim(500 + seed, boardW, boardH)
      for turn in 0 ..< 40:
        if sim.done:
          break
        for seat in 0 ..< Seats:
          if not sim.stats[seat].alive:
            continue
          let view = sim.viewOf(seat)
          for kind in [skSprawl, skCrown]:
            let plan = scriptedPlan(view, kind)
            states.inc
            check plan.intent in {inExpand, inGather, inAttack, inDefend,
              inScout, inRaid}
            check plan.reserve >= 0 and plan.reserve <= 999
            check plan.scouts >= 0 and plan.scouts <= 3
            check plan.cities in {cpNever, cpCheap, cpAlways}
            check plan.note.len == 0
            if plan.hasTarget:
              check plan.targetX >= 0 and plan.targetX < view.w
              check plan.targetY >= 0 and plan.targetY < view.h
            ## The serialised plan is small enough to be free.
            check ($planJson(plan)).len <= 256
        if sim.isDirectiveTurn():
          for seat in sim.aliveSeats():
            let kind = if seat mod 2 == 0: skSprawl else: skCrown
            sim.installPlan(seat, scriptedPlan(sim.viewOf(seat), kind),
              psScripted, 0)
        sim.stepTurn()
    check states >= 300
    discard rng

  test "a threatened crown always answers defend, for both baselines":
    var sim = episodeSim(31)
    ## Park an enemy stack next to red's crown.
    let crown = sim.board.generalCell[0]
    let x = sim.board.cellX(crown)
    let y = sim.board.cellY(crown)
    let near = sim.board.cellIndex(x + 1, y)
    sim.board.kind[near] = int8(ord(ckPlain))
    sim.board.owner[near] = 1
    sim.board.army[near] = 500
    sim.recountSeats()
    sim.recomputeVision()
    sim.memory[0].rememberVisible(sim.board, sim.visible[0], 0)
    let view = sim.viewOf(0)
    check view.threatened()
    check sprawlPlan(view).intent == inDefend
    check crownPlan(view).intent == inDefend

suite "the head-to-head and the tuning pick":
  test "sprawl finishes ahead of crown over the tuning seed set":
    ## The design note's claim, measured the way the tuning tool measures it:
    ## every seed and all four rotations of the seat assignment, so a corner
    ## cannot decide the answer in a four-way free-for-all.
    var sprawlTotal = 0.0
    var crownTotal = 0.0
    for seed in [1734029581, 42, 7, 99]:
      for rotation in 0 ..< Seats:
        var kinds: array[Seats, ScriptKind]
        for seat in 0 ..< Seats:
          kinds[seat] =
            if ((seat + rotation) mod 2) == 0: skSprawl else: skCrown
        var sim = episodeSim(seed)
        while not sim.done:
          if sim.isDirectiveTurn():
            for seat in sim.aliveSeats():
              sim.installPlan(seat,
                scriptedPlan(sim.viewOf(seat), kinds[seat]), psScripted, 0)
          sim.stepTurn()
        check sim.reason == "complete"
        let scores = sim.rankSeats(sim.turnsPlayed())
        for seat in 0 ..< Seats:
          if kinds[seat] == skSprawl: sprawlTotal += placementScore(scores[seat])
          else: crownTotal += placementScore(scores[seat])
    check sprawlTotal > crownTotal

  test "the seed-42 certification fixture exercises every beat kind":
    var config = defaultGameConfig()
    config.seed = 42
    config.turnSpacingMs = 0
    config.wallClockBudgetSeconds = 240
    config.lobbyJoinTimeoutTicks = 600
    config.players = @[]
    for seat in 0 ..< Seats:
      config.players.add(PlayerConfig(name: "seat-" & $seat))
    var sim = gensim.initSim(config)
    let kinds = [skSprawl, skCrown, skSprawl, skCrown]
    var cityTaken = 0
    var spotted = 0
    var growth = 0
    while not sim.done:
      if sim.isDirectiveTurn():
        for seat in sim.aliveSeats():
          sim.installPlan(seat, scriptedPlan(sim.viewOf(seat), kinds[seat]),
            psScripted, 0)
      sim.stepTurn()
      for event in sim.frameEvents:
        case event{"k"}.getStr()
        of "citytaken": cityTaken.inc
        of "generalspotted": spotted.inc
        of "growth": growth.inc
        else: discard
    check cityTaken >= 1
    check spotted >= 1
    check growth >= 1

  test "the shipped knobs ARE tools/ci/baseline_tuning.json's pick":
    var path = "tools/ci/baseline_tuning.json"
    if not fileExists(path):
      path = "../tools/ci/baseline_tuning.json"
    check fileExists(path)
    let document = parseJson(readFile(path))
    let picked = document["picked"]
    check picked["sprawlLandDivisor"].getInt() ==
      DefaultTuning.sprawlLandDivisor
    check picked["crownReserve"].getInt() == DefaultTuning.crownReserve
    check picked["crownScouts"].getInt() == DefaultTuning.crownScouts
    check document["margin"].getFloat() > 0.0
    ## The values the rules document, spelled out.
    check DefaultTuning.sprawlLandDivisor == 4
    check DefaultTuning.crownReserve == 20
    check DefaultTuning.crownScouts == 2
    let rules = readFile(
      if fileExists("docs/RULES.md"): "docs/RULES.md" else: "../docs/RULES.md")
    check "reserve` 20" in rules or "`reserve` 20" in rules
