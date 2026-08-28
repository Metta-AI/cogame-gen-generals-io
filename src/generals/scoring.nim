## The rank ladder. PURE INTEGER: the placement points that turn a rank into
## `results.scores` are produced at SERIALISATION time, in `roster.nim`, and
## never enter the sim -- which is why a CI grep can refuse a floating point
## routine in this file.
##
## `sum(scores) == Seats / 2 == 2.0` on every episode, ties included: a
## strictly constant-sum four-way game, which is what the platform's Elo
## wants to eat. Higher is better and no term is ever negative.

import sim_types, sim_state

type
  SeatRank* = object
    rank*: int          ## standard competition rank, 0 is best
    groupSize*: int     ## how many seats share this rank
    win*: bool

proc outTurn*(sim: Sim, seat: int, turnsPlayed: int): int =
  if sim.stats[seat].alive: turnsPlayed
  else: sim.stats[seat].eliminatedTurn

proc ranksAbove*(sim: Sim, a, b, turnsPlayed: int): int =
  ## -1 when a ranks strictly higher, 1 when b does, 0 on a genuine tie.
  ## The FIRST difference decides.
  let aliveA = sim.stats[a].alive
  let aliveB = sim.stats[b].alive
  if aliveA != aliveB:
    return (if aliveA: -1 else: 1)
  let outA = sim.outTurn(a, turnsPlayed)
  let outB = sim.outTurn(b, turnsPlayed)
  if outA != outB:
    return (if outA > outB: -1 else: 1)
  if sim.stats[a].land != sim.stats[b].land:
    return (if sim.stats[a].land > sim.stats[b].land: -1 else: 1)
  if sim.stats[a].army != sim.stats[b].army:
    return (if sim.stats[a].army > sim.stats[b].army: -1 else: 1)
  if sim.stats[a].cities != sim.stats[b].cities:
    return (if sim.stats[a].cities > sim.stats[b].cities: -1 else: 1)
  0

proc rankSeats*(sim: Sim, turnsPlayed: int): array[Seats, SeatRank] =
  ## Standard competition rank; a tie group of size n starting at rank r
  ## occupies ranks r .. r+n-1.
  var strictlyAbove: array[Seats, int]
  for a in 0 ..< Seats:
    strictlyAbove[a] = 0
    for b in 0 ..< Seats:
      if a == b:
        continue
      if sim.ranksAbove(a, b, turnsPlayed) > 0:
        strictlyAbove[a].inc
  for seat in 0 ..< Seats:
    var groupSize = 0
    for other in 0 ..< Seats:
      if strictlyAbove[other] == strictlyAbove[seat]:
        groupSize.inc
    result[seat] = SeatRank(
      rank: strictlyAbove[seat],
      groupSize: groupSize,
      win: strictlyAbove[seat] == 0)

proc winnerSeat*(scores: array[Seats, SeatRank]): int =
  ## The seat with rank 0 when exactly one has it, otherwise -1 (null).
  var found = -1
  var count = 0
  for seat in 0 ..< Seats:
    if scores[seat].rank == 0:
      count.inc
      found = seat
  if count == 1: found else: -1
