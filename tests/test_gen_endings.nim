## Test 4 -- the closed end-condition enums.

import std/[json]
import std/[unittest, os, strutils, tables]
import generals/sim as gensim
import generals/roster

proc freshSim(seed = 1734029581): Sim =
  var config = defaultGameConfig()
  config.seed = seed
  config.players = @[]
  for seat in 0 ..< Seats:
    config.players.add(PlayerConfig(name: "seat-" & $seat))
  gensim.initSim(config)

proc runScripted(sim: var Sim, kinds: array[Seats, ScriptKind]) =
  while not sim.done:
    if sim.isDirectiveTurn():
      for seat in sim.aliveSeats():
        sim.installPlan(seat, scriptedPlan(sim.viewOf(seat), kinds[seat]),
          psScripted, 0)
    sim.stepTurn()

suite "end conditions":
  test "conquest fires the turn the third crown falls, and not before":
    var sim = freshSim()
    ## Take three crowns by hand, one turn apart.
    for victim in 1 ..< Seats:
      check not sim.done
      let crown = sim.board.generalCell[victim]
      let x = sim.board.cellX(crown)
      let y = sim.board.cellY(crown)
      let approach = sim.board.cellIndex(x - 1, y)
      sim.board.kind[approach] = int8(ord(ckPlain))
      sim.board.owner[approach] = 0
      sim.board.army[approach] = 400
      sim.recountSeats()
      check sim.aliveCount() == Seats - (victim - 1)
      sim.applyMove(0, Move(fromCell: approach, dir: dirE, amount: 399))
      sim.checkEndConditions()
    check sim.done
    check sim.reason == "complete"
    check sim.endRule == "conquest"
    check sim.aliveCount() == 1

  test "full_time fires at exactly maxTurns and not the turn before":
    var sim = freshSim()
    let kinds = [skSprawl, skCrown, skSprawl, skCrown]
    while sim.turn < sim.config.maxTurns - 1 and not sim.done:
      if sim.isDirectiveTurn():
        for seat in sim.aliveSeats():
          sim.installPlan(seat, scriptedPlan(sim.viewOf(seat), kinds[seat]),
            psScripted, 0)
      sim.stepTurn()
    check not sim.done
    check sim.turn == sim.config.maxTurns - 1
    sim.stepTurn()
    check sim.done
    check sim.reason == "complete"
    check sim.endRule == "full_time"
    check sim.turn == sim.config.maxTurns

  test "the wall-clock stop is rankable and applied by one proc":
    var sim = freshSim()
    let kinds = [skSprawl, skCrown, skSprawl, skCrown]
    while sim.turn < 96 and not sim.done:
      if sim.isDirectiveTurn():
        for seat in sim.aliveSeats():
          sim.installPlan(seat, scriptedPlan(sim.viewOf(seat), kinds[seat]),
            psScripted, 0)
      sim.stepTurn()
    sim.applyWallClockStop(sim.turn)
    check sim.done
    check sim.reason == "deadline"
    check sim.endRule == "wall_clock"
    let results = generalsResultsJson(sim)
    var total = 0.0
    for score in results["scores"]:
      total += score.getFloat()
    check abs(total - 2.0) < 1e-9
    check results["turnsPlayed"].getInt() == 96

  test "a sim guard trip is a fault with a partial result":
    var sim = freshSim()
    sim.stepTurn()
    ## Forge an impossible board: a mountain that somebody owns.
    for cell in 0 ..< sim.board.cellCount():
      if sim.board.kindOf(cell) == ckMountain:
        sim.board.owner[cell] = 0
        break
    var tripped = false
    try:
      sim.checkGeneralsInvariants()
    except GenGuardError:
      tripped = true
    check tripped
    sim.finish("fault", "sim_fault")
    check sim.reason == "fault"
    check sim.endRule == "sim_fault"

  test "reason and endRule are always members of the declared enums":
    for seed in [1734029581, 42, 7, 31337]:
      var sim = freshSim(seed)
      runScripted(sim, [skSprawl, skCrown, skSprawl, skCrown])
      check sim.reason in LegalReasons
      check sim.endRule in LegalEndRules
      let results = generalsResultsJson(sim)
      check results["reason"].getStr() in LegalReasons
      check results["endRule"].getStr() in LegalEndRules

