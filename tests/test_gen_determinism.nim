## Test 5 -- determinism and the integer-only sim path.

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

proc streamOf(seed: int, kinds: array[Seats, ScriptKind]):
    (seq[uint32], seq[string], string) =
  ## The per-turn hash stream, the per-turn board bytes and the results
  ## document of one episode.
  var sim = freshSim(seed)
  var hashes = @[sim.gameHash()]
  var states = @[$sim.board.army & "|" & $sim.board.owner & "|" &
    $sim.board.kind]
  while not sim.done:
    if sim.isDirectiveTurn():
      for seat in sim.aliveSeats():
        sim.installPlan(seat, scriptedPlan(sim.viewOf(seat), kinds[seat]),
          psScripted, 0)
    sim.stepTurn()
    hashes.add(sim.gameHash())
    states.add($sim.board.army & "|" & $sim.board.owner & "|" &
      $sim.board.kind)
  (hashes, states, $generalsResultsJson(sim))

suite "determinism":
  test "no floating point in the sim path":
    const files = ["sim", "board", "vision", "resolve", "scoring", "captain",
      "baselines"]
    for name in files:
      var path = "src/generals/" & name & ".nim"
      if not fileExists(path):
        path = "../src/generals/" & name & ".nim"
      check fileExists(path)
      for line in readFile(path).splitLines():
        let code = line.split("##")[0].split("#")[0]
        for banned in ["float", "sqrt(", "hypot(", "sin(", "cos("]:
          if banned in code:
            checkpoint(path & ": " & line)
            check false

  test "the same seed and the same plans give byte-identical streams":
    ## The STREAM, turn by turn -- not just the final state. A divergence
    ## that cancels out before the last turn is still a divergence, and the
    ## end-state comparison this test used to make could not see it.
    let kinds = [skSprawl, skCrown, skSprawl, skCrown]
    let (hashesA, statesA, endA) = streamOf(1734029581, kinds)
    let (hashesB, statesB, endB) = streamOf(1734029581, kinds)
    check hashesA.len > 100
    check hashesA.len == statesA.len
    check hashesA == hashesB
    check statesA == statesB
    for turn in 0 ..< hashesA.len:
      if hashesA[turn] != hashesB[turn]:
        checkpoint("first divergence at turn " & $turn)
        check false
        break
    check endA == endB

  test "two different seeds do NOT give the same stream":
    var a = freshSim(1)
    var b = freshSim(2)
    let kinds = [skSprawl, skCrown, skSprawl, skCrown]
    runScripted(a, kinds)
    runScripted(b, kinds)
    check a.gameHash() != b.gameHash()

  test "the fog memory digest is inside gameHash":
    var sim = freshSim()
    for turn in 0 ..< 20:
      sim.stepTurn()
    let before = sim.gameHash()
    ## Forge a memory divergence and nothing else.
    for cell in 0 ..< sim.board.cellCount():
      if sim.memory[0].seenTurn[cell] < 0:
        sim.memory[0].seenTurn[cell] = 3
        sim.memory[0].kindSeen[cell] = int8(ord(ckCity))
        break
    check sim.gameHash() != before

  test "per-cell armies stay inside the 100000 guard under a snowball":
    var sim = freshSim(31337)
    runScripted(sim, [skSprawl, skSprawl, skCrown, skCrown])
    for cell in 0 ..< sim.board.cellCount():
      check sim.board.armyOf(cell) >= 0
      check sim.board.armyOf(cell) <= MaxCellArmy
    sim.checkGeneralsInvariants()
