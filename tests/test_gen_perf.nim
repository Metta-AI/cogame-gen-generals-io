## Test 6 — the perf bound.
##
## A full 240-turn four-seat episode with four captains must complete well
## inside the wall-clock budget the engine assumes for it (§Decisions puts
## the whole integer sim at ~2 s); this bounds it at 60 s so a pathological
## regression in the BFS or the flow-field cache fails the build rather than
## the hosted episode.

import std/[unittest, times]
import generals/sim as gensim

suite "perf":
  test "a 240-turn four-seat episode finishes inside 60 s":
    var config = defaultGameConfig()
    config.players = @[]
    for seat in 0 ..< Seats:
      config.players.add(PlayerConfig(name: "seat-" & $seat))
    var sim = gensim.initSim(config)
    let kinds = [skSprawl, skCrown, skSprawl, skCrown]
    let started = epochTime()
    while not sim.done:
      if sim.isDirectiveTurn():
        for seat in sim.aliveSeats():
          sim.installPlan(seat, scriptedPlan(sim.viewOf(seat), kinds[seat]),
            psScripted, 0)
      sim.stepTurn()
    let elapsed = epochTime() - started
    echo "240 turns in ", int(elapsed * 1000.0), " ms"
    check elapsed < 60.0
    check sim.turn == config.maxTurns or sim.endRule == "conquest"
