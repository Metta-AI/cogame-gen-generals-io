## Test 3 — the rank ladder and its sign.

import std/[unittest, random]
import generals/sim as gensim
import generals/roster

proc blankSim(): Sim =
  var config = defaultGameConfig()
  config.players = @[]
  for seat in 0 ..< Seats:
    config.players.add(PlayerConfig(name: "seat-" & $seat))
  gensim.initSim(config)

suite "scoring":
  test "sum(scores) is exactly 2.0 on every end state, ties included":
    var rng = initRand(20260828)
    var sim = blankSim()
    for trial in 0 ..< 5000:
      for seat in 0 ..< Seats:
        sim.stats[seat].alive = rng.rand(1) == 1
        sim.stats[seat].eliminatedTurn =
          if sim.stats[seat].alive: -1 else: rng.rand(240)
        sim.stats[seat].land = rng.rand(3)
        sim.stats[seat].army = int64(rng.rand(3))
        sim.stats[seat].cities = rng.rand(2)
      let scores = sim.rankSeats(240)
      var total = 0.0
      for seat in 0 ..< Seats:
        total += placementScore(scores[seat])
        check placementScore(scores[seat]) >= 0.0
        check placementScore(scores[seat]) <= 1.0
      check abs(total - 2.0) < 1e-9

  test "every tie shape sums to 2.0":
    var sim = blankSim()
    for shape in 0 ..< 3:
      for seat in 0 ..< Seats:
        sim.stats[seat] = SeatStats(alive: true, eliminatedTurn: -1,
          eliminatedBy: -1)
      case shape
      of 0:
        sim.stats[0].land = 5
        sim.stats[1].land = 5
      of 1:
        sim.stats[0].land = 5
        sim.stats[1].land = 5
        sim.stats[2].land = 5
      else:
        discard
      let scores = sim.rankSeats(240)
      var total = 0.0
      for seat in 0 ..< Seats:
        total += placementScore(scores[seat])
      check abs(total - 2.0) < 1e-9

  test "the ladder resolves in order alive, outTurn, land, army, cities":
    var sim = blankSim()
    for seat in 0 ..< Seats:
      sim.stats[seat] = SeatStats(alive: true, eliminatedTurn: -1,
        eliminatedBy: -1, land: 10, army: 10, cities: 1)
    ## alive beats everything
    sim.stats[0].alive = false
    sim.stats[0].eliminatedTurn = 200
    sim.stats[0].land = 99
    sim.stats[0].army = 999
    sim.stats[0].cities = 9
    var scores = sim.rankSeats(240)
    check scores[0].rank == 3
    ## among the dead, who lasted longer
    sim.stats[1].alive = false
    sim.stats[1].eliminatedTurn = 100
    scores = sim.rankSeats(240)
    check scores[0].rank < scores[1].rank
    ## land, then army, then cities among the living
    sim.stats[2].land = 11
    scores = sim.rankSeats(240)
    check scores[2].rank == 0
    sim.stats[3].land = 11
    sim.stats[3].army = 12
    scores = sim.rankSeats(240)
    check scores[3].rank == 0
    sim.stats[2].army = 12
    sim.stats[2].cities = 5
    scores = sim.rankSeats(240)
    check scores[2].rank == 0

  test "win is exactly rank 0 and winner is null on a shared top rank":
    var sim = blankSim()
    for seat in 0 ..< Seats:
      sim.stats[seat] = SeatStats(alive: true, eliminatedTurn: -1,
        eliminatedBy: -1, land: 5, army: 5, cities: 0)
    var scores = sim.rankSeats(240)
    for seat in 0 ..< Seats:
      check scores[seat].win == (scores[seat].rank == 0)
    check winnerSeat(scores) == -1
    sim.stats[2].land = 6
    scores = sim.rankSeats(240)
    check winnerSeat(scores) == 2
    check scores[2].win
    check placementScore(scores[2]) == 1.0

  test "a deadline episode is scored by the same ladder, never zeroed":
    var sim = blankSim()
    for seat in 0 ..< Seats:
      sim.stats[seat] = SeatStats(alive: true, eliminatedTurn: -1,
        eliminatedBy: -1, land: 4 + seat, army: 10, cities: 0)
    sim.applyWallClockStop(96)
    check sim.reason == "deadline"
    check sim.endRule == "wall_clock"
    let scores = sim.rankSeats(96)
    var total = 0.0
    for seat in 0 ..< Seats:
      total += placementScore(scores[seat])
    check abs(total - 2.0) < 1e-9
    check scores[3].rank == 0
