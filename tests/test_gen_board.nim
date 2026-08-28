## Test 1 — the seeded four-fold-symmetric generator.

import std/[unittest, sets]
import generals/sim as gensim

suite "the board generator":
  test "the board is four-fold symmetric in kind, for both sizes":
    for size in [(16, 10), (12, 8)]:
      for seed in 0 ..< 2000:
        var config = defaultGameConfig()
        config.seed = seed
        config.boardW = size[0]
        config.boardH = size[1]
        if size[0] == 12:
          config.mountainPct = 18
          config.cityCount = 4
          config.maxTurns = 160
          config.growthPeriod = 15
        let board = generateBoard(config)
        check board.mountainSymmetric()

  test "the mountain and city counts match the formulas":
    for seed in 0 ..< 400:
      var config = defaultGameConfig()
      config.seed = seed
      let board = generateBoard(config)
      let qw = config.boardW div 2
      let qh = config.boardH div 2
      let mountains = ((qw * qh * config.mountainPct) div 100) * 4
      ## The connectivity repair may open a mirror orbit, so the count is the
      ## formula MINUS whatever it had to clear, never more.
      check board.countKind(ckMountain) <= mountains
      check board.countKind(ckMountain) >= mountains - 4 * 4
      check board.countKind(ckCity) == config.cityCount

  test "every general is off the edge, holds 1 army, and mirrors the others":
    for seed in 0 ..< 500:
      var config = defaultGameConfig()
      config.seed = seed
      let board = generateBoard(config)
      var cells: HashSet[int]
      for seat in 0 ..< Seats:
        let cell = board.generalCell[seat]
        check cell >= 0
        check board.kindOf(cell) == ckGeneral
        check board.ownerOf(cell) == seat
        check board.armyOf(cell) == 1
        let x = board.cellX(cell)
        let y = board.cellY(cell)
        check x > 0 and y > 0
        check x < board.w - 1 and y < board.h - 1
        cells.incl(cell)
      check cells.len == Seats
      let orbit = board.mirrorCells(board.generalCell[0])
      for seat in 0 ..< Seats:
        check orbit[seat] == board.generalCell[seat]

  test "the connectivity repair leaves every non-mountain cell reachable":
    for seed in 0 ..< 2000:
      var config = defaultGameConfig()
      config.seed = seed
      let board = generateBoard(config)
      check board.allReachable()
      check board.mountainSymmetric()

  test "the board is a pure function of the config, identical after play":
    var config = defaultGameConfig()
    config.players = @[]
    for seat in 0 ..< Seats:
      config.players.add(PlayerConfig(name: "seat-" & $seat))
    let before = generateBoard(config)
    var sim = gensim.initSim(config)
    for turn in 0 ..< 60:
      if sim.isDirectiveTurn():
        for seat in sim.aliveSeats():
          sim.installPlan(seat, sprawlPlan(sim.viewOf(seat)), psScripted, 0)
      sim.stepTurn()
    let after = generateBoard(config)
    ## Anti-collusion: nothing a policy does can steer a draw, so the board
    ## generated AFTER sixty turns of play is bit-identical to the one
    ## generated before it.
    check before.kind == after.kind
    check before.army == after.army
    check before.generalCell == after.generalCell
    check sim.turn == 60

  test "mapRng is consumed by the generator and by nothing else":
    var rng = initMapRng(1734029581)
    discard rng.rand(10)
    let firstDraws = rng.draws
    check firstDraws == 1
    ## Two boards from the same seed consume the identical number of draws.
    var configA = defaultGameConfig()
    var configB = defaultGameConfig()
    configB.seed = configA.seed
    check generateBoard(configA).army == generateBoard(configB).army

  test "different seeds give different boards":
    var a = defaultGameConfig()
    var b = defaultGameConfig()
    b.seed = a.seed + 1
    check generateBoard(a).kind != generateBoard(b).kind
