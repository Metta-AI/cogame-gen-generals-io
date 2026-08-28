## Test 2 — the ordered resolution rules, one case per numbered step.

import std/[json]
import std/[unittest]
import generals/sim as gensim

proc blankSim(): Sim =
  var config = defaultGameConfig()
  config.players = @[]
  for seat in 0 ..< Seats:
    config.players.add(PlayerConfig(name: "seat-" & $seat))
  result = gensim.initSim(config)

proc clearBoard(sim: var Sim) =
  ## A bare board with one crown per seat in a fixed corner, so a rule can be
  ## exercised without the generator's mountains in the way.
  for cell in 0 ..< sim.board.cellCount():
    sim.board.kind[cell] = int8(ord(ckPlain))
    sim.board.owner[cell] = NoOwner
    sim.board.army[cell] = 0
  let crowns = [sim.board.cellIndex(1, 1),
                sim.board.cellIndex(sim.board.w - 2, 1),
                sim.board.cellIndex(1, sim.board.h - 2),
                sim.board.cellIndex(sim.board.w - 2, sim.board.h - 2)]
  for seat in 0 ..< Seats:
    sim.board.kind[crowns[seat]] = int8(ord(ckGeneral))
    sim.board.owner[crowns[seat]] = int8(seat)
    sim.board.army[crowns[seat]] = 1
    sim.board.generalCell[seat] = crowns[seat]
    sim.stats[seat] = SeatStats(alive: true, eliminatedTurn: -1,
      eliminatedBy: -1)
  sim.recountSeats()
  sim.recomputeVision()

proc own(sim: var Sim, x, y, seat, army: int) =
  let cell = sim.board.cellIndex(x, y)
  sim.board.owner[cell] = int8(seat)
  sim.board.army[cell] = int32(army)
  sim.recountSeats()

suite "resolution: legality":
  test "a move from an unowned cell is discarded and changes nothing":
    var sim = blankSim()
    sim.clearBoard()
    sim.own(5, 5, 0, 10)
    let armiesBefore = sim.board.army
    let ownersBefore = sim.board.owner
    sim.applyMove(1, Move(fromCell: sim.board.cellIndex(5, 5), dir: dirE,
      amount: 5))
    ## Nothing on the board moved; only the seat's own invalidMoves counter
    ## did, which is exactly what "costs nothing else" means.
    check sim.stats[1].invalidMoves == 1
    check sim.board.army == armiesBefore
    check sim.board.owner == ownersBefore
    check sim.stats[1].movesMade == 0

  test "a move from a 1-army cell is discarded":
    var sim = blankSim()
    sim.clearBoard()
    sim.own(5, 5, 0, 1)
    sim.applyMove(0, Move(fromCell: sim.board.cellIndex(5, 5), dir: dirE,
      amount: 1))
    check sim.stats[0].invalidMoves == 1
    check sim.board.armyOf(sim.board.cellIndex(5, 5)) == 1

  test "a move off the board is discarded":
    var sim = blankSim()
    sim.clearBoard()
    sim.own(0, 0, 0, 10)
    sim.applyMove(0, Move(fromCell: sim.board.cellIndex(0, 0), dir: dirW,
      amount: 5))
    check sim.stats[0].invalidMoves == 1
    check sim.board.armyOf(sim.board.cellIndex(0, 0)) == 10

  test "a move onto a mountain is discarded":
    var sim = blankSim()
    sim.clearBoard()
    sim.own(5, 5, 0, 10)
    sim.board.kind[sim.board.cellIndex(6, 5)] = int8(ord(ckMountain))
    sim.applyMove(0, Move(fromCell: sim.board.cellIndex(5, 5), dir: dirE,
      amount: 5))
    check sim.stats[0].invalidMoves == 1
    check sim.board.armyOf(sim.board.cellIndex(5, 5)) == 10

suite "resolution: arithmetic":
  test "amount is clamped into 1 .. army - 1 and the source keeps one":
    var sim = blankSim()
    sim.clearBoard()
    sim.own(5, 5, 0, 10)
    sim.applyMove(0, Move(fromCell: sim.board.cellIndex(5, 5), dir: dirE,
      amount: 999))
    check sim.board.armyOf(sim.board.cellIndex(5, 5)) == 1
    check sim.board.armyOf(sim.board.cellIndex(6, 5)) == 9
    sim.own(1, 5, 0, 4)
    sim.applyMove(0, Move(fromCell: sim.board.cellIndex(1, 5), dir: dirE,
      amount: -8))
    check sim.board.armyOf(sim.board.cellIndex(1, 5)) == 3
    check sim.board.armyOf(sim.board.cellIndex(2, 5)) == 1

  test "a friendly target adds, and land and cities do not change":
    var sim = blankSim()
    sim.clearBoard()
    sim.own(5, 5, 0, 10)
    sim.own(6, 5, 0, 3)
    let land = sim.stats[0].land
    sim.applyMove(0, Move(fromCell: sim.board.cellIndex(5, 5), dir: dirE,
      amount: 9))
    check sim.board.armyOf(sim.board.cellIndex(6, 5)) == 12
    check sim.stats[0].land == land
    check sim.stats[0].cities == 0

  test "one army takes an empty plain and leaves one on it":
    var sim = blankSim()
    sim.clearBoard()
    sim.own(5, 5, 0, 2)
    sim.applyMove(0, Move(fromCell: sim.board.cellIndex(5, 5), dir: dirE,
      amount: 1))
    check sim.board.ownerOf(sim.board.cellIndex(6, 5)) == 0
    check sim.board.armyOf(sim.board.cellIndex(6, 5)) == 1

  test "40 against a 40-garrison city fails; 41 takes it":
    var sim = blankSim()
    sim.clearBoard()
    let city = sim.board.cellIndex(6, 5)
    sim.board.kind[city] = int8(ord(ckCity))
    sim.board.army[city] = 40
    sim.own(5, 5, 0, 41)
    sim.applyMove(0, Move(fromCell: sim.board.cellIndex(5, 5), dir: dirE,
      amount: 40))
    check sim.board.ownerOf(city) == -1
    check sim.board.armyOf(city) == 0
    check sim.stats[0].cities == 0
    sim.own(5, 5, 0, 42)
    sim.board.army[city] = 40
    sim.recountSeats()
    sim.applyMove(0, Move(fromCell: sim.board.cellIndex(5, 5), dir: dirE,
      amount: 41))
    check sim.board.ownerOf(city) == 0
    check sim.board.armyOf(city) == 1
    check sim.stats[0].cities == 1

  test "an enemy tile flips only when the attacker sends more":
    var sim = blankSim()
    sim.clearBoard()
    sim.own(5, 5, 0, 20)
    sim.own(6, 5, 1, 5)
    sim.applyMove(0, Move(fromCell: sim.board.cellIndex(5, 5), dir: dirE,
      amount: 5))
    check sim.board.ownerOf(sim.board.cellIndex(6, 5)) == 1
    check sim.board.armyOf(sim.board.cellIndex(6, 5)) == 0
    sim.own(6, 5, 1, 9)
    sim.own(5, 5, 0, 6)
    sim.applyMove(0, Move(fromCell: sim.board.cellIndex(5, 5), dir: dirE,
      amount: 5))
    check sim.board.ownerOf(sim.board.cellIndex(6, 5)) == 1
    check sim.board.armyOf(sim.board.cellIndex(6, 5)) == 4
    sim.own(5, 5, 0, 11)
    sim.applyMove(0, Move(fromCell: sim.board.cellIndex(5, 5), dir: dirE,
      amount: 10))
    check sim.board.ownerOf(sim.board.cellIndex(6, 5)) == 0
    check sim.board.armyOf(sim.board.cellIndex(6, 5)) == 6

suite "resolution: rotated priority":
  test "the seat that moves FIRST on turn t is seat t mod 4":
    ## The note's claim, asserted directly: two seats push the same empty
    ## cell with the same force, so the first mover takes it and the second
    ## only strips it back to zero without flipping it. The survivor names
    ## who had priority.
    for turn in 0 ..< 8:
      var sim = blankSim()
      sim.clearBoard()
      sim.turn = turn
      let target = sim.board.cellIndex(8, 5)
      let sources = [(7, 5, dirE), (9, 5, dirW), (8, 4, dirS), (8, 6, dirN)]
      var moves: array[Seats, Move]
      var hasMove: array[Seats, bool]
      let first = turn mod Seats
      let second = (turn + 1) mod Seats
      for seat in [first, second]:
        sim.own(sources[seat][0], sources[seat][1], seat, 6)
        moves[seat] = Move(
          fromCell: sim.board.cellIndex(sources[seat][0], sources[seat][1]),
          dir: sources[seat][2], amount: 5)
        hasMove[seat] = true
      sim.resolveMoves(moves, hasMove)
      check sim.board.ownerOf(target) == first
      check sim.board.armyOf(target) == 0

  test "with all four contesting, the survivor is the THIRD mover, (t + 2) mod 4":
    for turn in 0 ..< 8:
      var sim = blankSim()
      sim.clearBoard()
      sim.turn = turn
      let target = sim.board.cellIndex(8, 5)
      var moves: array[Seats, Move]
      var hasMove: array[Seats, bool]
      let sources = [(7, 5, dirE), (9, 5, dirW), (8, 4, dirS), (8, 6, dirN)]
      for seat in 0 ..< Seats:
        sim.own(sources[seat][0], sources[seat][1], seat, 3)
        moves[seat] = Move(
          fromCell: sim.board.cellIndex(sources[seat][0], sources[seat][1]),
          dir: sources[seat][2], amount: 2)
        hasMove[seat] = true
      sim.resolveMoves(moves, hasMove)
      ## Four seats send 2 each at one empty cell, in the order
      ## (turn + 0 .. 3) mod 4. The first takes it with 2; the second sends 2
      ## against 2, which strips the garrison to 0 and does NOT flip it; the
      ## third takes the now-empty cell; the fourth strips it again. So the
      ## surviving owner is the THIRD mover, `(turn + 2) mod 4`, and the fact
      ## that it walks with the turn number is the rotation.
      check sim.board.ownerOf(target) == (turn + 2) mod Seats

  test "a seat whose source was captured earlier in the turn loses its move":
    var sim = blankSim()
    sim.clearBoard()
    sim.turn = 0
    sim.own(5, 5, 0, 20)
    sim.own(6, 5, 1, 3)
    var moves: array[Seats, Move]
    var hasMove: array[Seats, bool]
    moves[0] = Move(fromCell: sim.board.cellIndex(5, 5), dir: dirE, amount: 19)
    hasMove[0] = true
    moves[1] = Move(fromCell: sim.board.cellIndex(6, 5), dir: dirE, amount: 2)
    hasMove[1] = true
    sim.resolveMoves(moves, hasMove)
    check sim.board.ownerOf(sim.board.cellIndex(6, 5)) == 0
    check sim.stats[1].invalidMoves == 1
    check sim.board.ownerOf(sim.board.cellIndex(7, 5)) == -1

suite "resolution: crown capture":
  test "capturing a crown transfers every tile at half army":
    var sim = blankSim()
    sim.clearBoard()
    let victimCrown = sim.board.generalCell[1]
    sim.board.army[victimCrown] = 5
    sim.own(3, 3, 1, 7)
    sim.own(3, 4, 1, 1)
    let attacker = sim.board.cellX(victimCrown) - 1
    sim.own(attacker, sim.board.cellY(victimCrown), 0, 30)
    sim.recountSeats()
    sim.applyMove(0, Move(
      fromCell: sim.board.cellIndex(attacker, sim.board.cellY(victimCrown)),
      dir: dirE, amount: 29))
    check not sim.stats[1].alive
    check sim.stats[1].eliminatedBy == 0
    check sim.stats[1].land == 0
    check sim.stats[1].army == 0
    check sim.stats[1].cities == 0
    check sim.stats[0].generalsCaptured == 1
    check sim.board.kindOf(victimCrown) == ckCity
    check sim.board.ownerOf(victimCrown) == 0
    check sim.board.armyOf(victimCrown) == 24
    check sim.board.ownerOf(sim.board.cellIndex(3, 3)) == 0
    check sim.board.armyOf(sim.board.cellIndex(3, 3)) == 3
    ## A one-army tile halves to zero and is STILL owned.
    check sim.board.ownerOf(sim.board.cellIndex(3, 4)) == 0
    check sim.board.armyOf(sim.board.cellIndex(3, 4)) == 0

  test "a chain capture in one turn carries the inherited tiles too":
    var sim = blankSim()
    sim.clearBoard()
    sim.turn = 0
    let crownB = sim.board.generalCell[1]
    let crownA = sim.board.generalCell[0]
    sim.board.army[crownB] = 2
    sim.board.army[crownA] = 2
    sim.own(4, 4, 1, 9)
    let approachB = sim.board.cellIndex(sim.board.cellX(crownB) - 1,
      sim.board.cellY(crownB))
    sim.own(sim.board.cellX(approachB), sim.board.cellY(approachB), 0, 40)
    let approachA = sim.board.cellIndex(sim.board.cellX(crownA) + 1,
      sim.board.cellY(crownA))
    sim.own(sim.board.cellX(approachA), sim.board.cellY(approachA), 2, 80)
    sim.recountSeats()
    var moves: array[Seats, Move]
    var hasMove: array[Seats, bool]
    moves[0] = Move(fromCell: approachB, dir: dirE, amount: 39)
    hasMove[0] = true
    moves[2] = Move(fromCell: approachA, dir: dirW, amount: 79)
    hasMove[2] = true
    sim.resolveMoves(moves, hasMove)
    check not sim.stats[1].alive
    check not sim.stats[0].alive
    check sim.stats[2].alive
    ## B's tile went to A, then A's whole estate went to C.
    check sim.board.ownerOf(sim.board.cellIndex(4, 4)) == 2

suite "resolution: growth":
  test "owned cities and crowns grow every turn; neutral cities do not":
    var sim = blankSim()
    sim.clearBoard()
    let neutral = sim.board.cellIndex(8, 5)
    sim.board.kind[neutral] = int8(ord(ckCity))
    sim.board.army[neutral] = 40
    let owned = sim.board.cellIndex(9, 5)
    sim.board.kind[owned] = int8(ord(ckCity))
    sim.board.owner[owned] = 0
    sim.board.army[owned] = 4
    sim.own(3, 3, 0, 5)
    sim.growPerTurn()
    check sim.board.armyOf(neutral) == 40
    check sim.board.armyOf(owned) == 5
    check sim.board.armyOf(sim.board.generalCell[0]) == 2
    check sim.board.armyOf(sim.board.cellIndex(3, 3)) == 5

  test "on a growth beat every owned cell gains exactly one":
    var sim = blankSim()
    sim.clearBoard()
    sim.own(3, 3, 0, 5)
    let neutral = sim.board.cellIndex(8, 5)
    sim.turn = sim.config.growthPeriod
    sim.growPeriodic()
    check sim.board.armyOf(sim.board.cellIndex(3, 3)) == 6
    check sim.board.armyOf(sim.board.generalCell[0]) == 2
    check sim.board.armyOf(neutral) == 0

suite "resolution: vision":
  test "visible is exactly owned plus its eight neighbours":
    var sim = blankSim()
    sim.clearBoard()
    sim.own(5, 5, 0, 3)
    sim.updateVisionAndMemory()
    var expected = 0
    for cell in 0 ..< sim.board.cellCount():
      let dx = abs(sim.board.cellX(cell) - 5)
      let dy = abs(sim.board.cellY(cell) - 5)
      let near = dx <= 1 and dy <= 1
      let crown = cell == sim.board.generalCell[0]
      let crownNear = abs(sim.board.cellX(cell) -
          sim.board.cellX(sim.board.generalCell[0])) <= 1 and
        abs(sim.board.cellY(cell) -
          sim.board.cellY(sim.board.generalCell[0])) <= 1
      if near or crown or crownNear:
        check sim.visible[0][cell]
        expected.inc
      else:
        check not sim.visible[0][cell]
    check expected > 0

  test "a cell that leaves vision keeps its memory and reports no army":
    var sim = blankSim()
    sim.clearBoard()
    sim.own(5, 5, 0, 3)
    sim.own(6, 5, 1, 4)
    sim.updateVisionAndMemory()
    var view = sim.viewOf(0)
    check view.isVisible(sim.board.cellIndex(6, 5))
    check view.knownArmy(sim.board.cellIndex(6, 5)) == 4
    ## Take the tile away and stand somewhere else entirely.
    sim.board.owner[sim.board.cellIndex(5, 5)] = NoOwner
    sim.board.army[sim.board.cellIndex(5, 5)] = 0
    sim.own(1, 8, 0, 3)
    sim.recountSeats()
    sim.updateVisionAndMemory()
    view = sim.viewOf(0)
    let remembered = sim.board.cellIndex(6, 5)
    check view.isRemembered(remembered)
    check view.knownOwner(remembered) == 1
    check view.knownArmy(remembered) == 0
    check view.seenTurn[remembered] >= 0

  test "generalspotted fires once per ordered pair":
    var sim = blankSim()
    sim.clearBoard()
    let victim = sim.board.generalCell[1]
    sim.own(sim.board.cellX(victim) - 1, sim.board.cellY(victim), 0, 3)
    sim.updateVisionAndMemory()
    var spotted = 0
    for event in sim.frameEvents:
      if event{"k"}.getStr() == "generalspotted":
        spotted.inc
    check spotted == 1
    sim.frameEvents = newJArray()
    sim.updateVisionAndMemory()
    for event in sim.frameEvents:
      check event{"k"}.getStr() != "generalspotted"
