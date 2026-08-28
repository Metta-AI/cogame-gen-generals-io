## Steps 3-5 of the turn: move resolution in rotated seat order, the crown
## capture inheritance, and the two growth rules. Pure integer.

import std/[json]
import sim_types, board, vision, sim_state, events

proc discardMove(sim: var Sim, seat: int) {.inline.} =
  sim.stats[seat].invalidMoves.inc

proc captureGeneral(sim: var Sim, attacker, victim, cell, surviving: int) =
  ## e. Crown capture, in the design note's sub-order.
  var landGained = 0
  var armyGained = 0
  for other in 0 ..< sim.board.cellCount():
    if other == cell:
      continue
    if sim.board.ownerOf(other) != victim:
      continue
    let halved = sim.board.armyOf(other) div 2
    sim.board.owner[other] = int8(attacker)
    sim.board.army[other] = int32(halved)
    landGained.inc
    armyGained += halved
  sim.stats[attacker].landInherited += landGained
  sim.stats[attacker].armyInherited += int64(armyGained)

  sim.board.kind[cell] = int8(ord(ckCity))
  sim.board.owner[cell] = int8(attacker)
  sim.board.army[cell] = int32(max(1, surviving))
  sim.board.generalCell[victim] = -1

  sim.stats[victim].alive = false
  sim.stats[victim].eliminatedTurn = sim.turn
  sim.stats[victim].eliminatedBy = attacker
  sim.stats[attacker].generalsCaptured.inc
  sim.recountSeats()
  sim.stats[victim].land = 0
  sim.stats[victim].army = 0
  sim.stats[victim].cities = 0

  sim.record(seGeneralCaptured, %*{
    "seat": attacker, "victim": victim, "cell": cell,
    "landGained": landGained, "armyGained": armyGained})
  sim.record(seEliminated, %*{
    "seat": victim, "turn": sim.turn, "by": attacker})

proc applyMove*(sim: var Sim, seat: int, move: Move) =
  ## One seat's move, fully evaluated against the already-updated board.
  if not sim.stats[seat].alive:
    sim.discardMove(seat)
    return
  let source = move.fromCell
  if source < 0 or source >= sim.board.cellCount():
    sim.discardMove(seat)
    return
  if sim.board.ownerOf(source) != seat or sim.board.armyOf(source) < 2:
    sim.discardMove(seat)
    return
  let (dx, dy) = dirDelta(move.dir)
  let tx = sim.board.cellX(source) + dx
  let ty = sim.board.cellY(source) + dy
  if not sim.board.onBoard(tx, ty):
    sim.discardMove(seat)
    return
  let target = sim.board.cellIndex(tx, ty)
  if sim.board.kindOf(target) == ckMountain:
    sim.discardMove(seat)
    return

  # b. amount
  let amount = clamp(move.amount, 1, sim.board.armyOf(source) - 1)
  sim.board.army[source] = int32(sim.board.armyOf(source) - amount)
  sim.stats[seat].movesMade.inc

  let previousOwner = sim.board.ownerOf(target)
  if previousOwner == seat:
    # c. friendly target
    sim.board.army[target] = int32(sim.board.armyOf(target) + amount)
    sim.recountSeats()
    return

  # d. neutral or hostile target
  let defence = sim.board.armyOf(target)
  if amount > defence:
    let surviving = amount - defence
    let targetKind = sim.board.kindOf(target)
    if targetKind == ckGeneral and previousOwner >= 0 and
        sim.stats[previousOwner].alive:
      sim.captureGeneral(seat, previousOwner, target, surviving)
      return
    sim.board.owner[target] = int8(seat)
    sim.board.army[target] = int32(surviving)
    sim.stats[seat].tilesTaken.inc
    if previousOwner >= 0:
      sim.stats[previousOwner].tilesLost.inc
      sim.record(seTileLost, %*{
        "seat": previousOwner, "to": seat, "cell": target, "count": 1})
    if targetKind == ckCity:
      sim.record(seCityTaken, %*{
        "seat": seat, "cell": target, "from": previousOwner,
        "cost": defence, "cities": sim.stats[seat].cities + 1})
    elif previousOwner < 0:
      sim.record(seClaim, %*{
        "seat": seat, "cell": target, "land": sim.stats[seat].land + 1})
  else:
    sim.board.army[target] = int32(defence - amount)
    if min(amount, defence) >= 10:
      sim.record(seStackClash, %*{
        "cell": target, "attacker": seat, "defender": previousOwner,
        "attackerArmy": amount, "defenderArmy": defence, "held": true})
  sim.recountSeats()

proc resolveMoves*(sim: var Sim, moves: array[Seats, Move],
    hasMove: array[Seats, bool]) =
  ## Rotated priority: order[k] = (turn + k) mod 4. Priority rounds the table
  ## every turn, so no seat has a standing advantage.
  for k in 0 ..< Seats:
    let seat = (sim.turn + k) mod Seats
    if not hasMove[seat]:
      continue
    sim.applyMove(seat, moves[seat])

proc growPerTurn*(sim: var Sim) =
  ## 4. Every OWNED city and general gains +1. Neutral cities do not grow.
  for cell in 0 ..< sim.board.cellCount():
    let kind = sim.board.kindOf(cell)
    if (kind == ckCity or kind == ckGeneral) and sim.board.ownerOf(cell) >= 0:
      sim.board.army[cell] = int32(min(MaxCellArmy, sim.board.armyOf(cell) + 1))
  sim.recountSeats()

proc growPeriodic*(sim: var Sim) =
  ## 5. On a growth beat every owned cell gains +1, whatever its kind.
  if sim.turn <= 0 or sim.turn mod sim.config.growthPeriod != 0:
    return
  for cell in 0 ..< sim.board.cellCount():
    if sim.board.ownerOf(cell) >= 0:
      sim.board.army[cell] = int32(min(MaxCellArmy, sim.board.armyOf(cell) + 1))
  sim.recountSeats()
  var landRow = newJArray()
  var armyRow = newJArray()
  for seat in 0 ..< Seats:
    landRow.add(%sim.stats[seat].land)
    armyRow.add(%int(sim.stats[seat].army))
  sim.record(seGrowth, %*{
    "turn": sim.turn, "land": landRow, "army": armyRow})

proc updateVisionAndMemory*(sim: var Sim) =
  ## 6. Vision and memory, plus the once-per-ordered-pair generalspotted.
  sim.recomputeVision()
  for seat in 0 ..< Seats:
    if not sim.stats[seat].alive:
      continue
    sim.memory[seat].rememberVisible(sim.board, sim.visible[seat], sim.turn)
    for victim in 0 ..< Seats:
      if victim == seat or not sim.stats[victim].alive:
        continue
      if sim.spotted[seat][victim]:
        continue
      let cell = sim.board.generalCell[victim]
      if cell >= 0 and sim.visible[seat][cell]:
        sim.spotted[seat][victim] = true
        sim.record(seGeneralSpotted, %*{
          "seat": seat, "victim": victim, "cell": cell})
