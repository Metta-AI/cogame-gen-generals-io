## Seat identity and the results document.
##
## Forked from coworld-ctf's `src/ctf/roster.nim`. `cogAlias`,
## `IdentityNames` and the two-name-space rule are UNTOUCHED (they live in
## `sim_types.nim`, exactly as the starter has them): in-game a seat is only
## ever `RED-alpha` / `BLUE-alpha` / `GREEN-alpha` / `YELLOW-alpha`, and the
## real policy names live only here, in the replay's join records, in the DOM
## scorebug and on the endcard.

import std/[json]
import sim_types, sim_state, scoring, sim as gensim

proc seatAuthorized*(config: auto, slot: int, token: string): bool =
  slot >= 0 and slot < config.tokens.len and config.tokens[slot] == token

proc placePoint*(rank: int): float =
  ## The placement point of one rank. Produced HERE, at serialisation time,
  ## from the integer rank: `scoring.nim` and the rest of the sim path are
  ## floating-point free and a CI grep enforces it.
  float(Seats - 1 - rank) / float(Seats - 1)

proc placementScore*(entry: SeatRank): float =
  ## A tie group of size n starting at rank r occupies ranks r .. r+n-1, and
  ## every member takes the AVERAGE of the placement points over that block.
  ## That is what keeps `sum(scores)` at exactly 2.0 on every episode.
  var total = 0.0
  for offset in 0 ..< entry.groupSize:
    total += placePoint(entry.rank + offset)
  total / float(entry.groupSize)

proc generalsResultsJson*(sim: Sim): JsonNode =
  ## Exactly the 29 keys the manifest's `results_schema` declares. Adding or
  ## removing one means editing `coworld_manifest_template.json` and
  ## `tools/ci/docker_smoke.sh`'s expected-key set in the same commit.
  let played = sim.turnsPlayed()
  let scores = sim.rankSeats(played)
  let winner = winnerSeat(scores)

  var names = newJArray()
  var aliases = newJArray()
  var scoreRow = newJArray()
  var winRow = newJArray()
  var rankRow = newJArray()
  var landRow = newJArray()
  var armyRow = newJArray()
  var citiesRow = newJArray()
  var capturedRow = newJArray()
  var outTurnRow = newJArray()
  var outByRow = newJArray()
  var takenRow = newJArray()
  var lostRow = newJArray()
  var movesRow = newJArray()
  var invalidRow = newJArray()
  var passRow = newJArray()
  var kindRow = newJArray()
  var llmRow = newJArray()
  var fallbackRow = newJArray()
  var rejectedRow = newJArray()
  var deadRow = newJArray()

  for seat in 0 ..< Seats:
    let stat = sim.stats[seat]
    names.add(%sim.names[seat])
    aliases.add(%cogAlias(seat))
    scoreRow.add(%placementScore(scores[seat]))
    winRow.add(%scores[seat].win)
    rankRow.add(%scores[seat].rank)
    landRow.add(%stat.land)
    armyRow.add(%int(stat.army))
    citiesRow.add(%stat.cities)
    capturedRow.add(%stat.generalsCaptured)
    outTurnRow.add(%stat.eliminatedTurn)
    outByRow.add(%stat.eliminatedBy)
    takenRow.add(%int(stat.tilesTaken))
    lostRow.add(%int(stat.tilesLost))
    movesRow.add(%int(stat.movesMade))
    invalidRow.add(%stat.invalidMoves)
    passRow.add(%stat.passes)
    kindRow.add(%sim.policyKinds[seat])
    llmRow.add(%stat.llmTurns)
    fallbackRow.add(%stat.fallbackTurns)
    rejectedRow.add(%stat.directivesRejected)
    deadRow.add(%stat.dead)

  %*{
    "names": names,
    "aliases": aliases,
    "scores": scoreRow,
    "win": winRow,
    "winner": (if winner >= 0: %winner else: newJNull()),
    "reason": sim.reason,
    "endRule": sim.endRule,
    "rank": rankRow,
    "land": landRow,
    "army": armyRow,
    "cities": citiesRow,
    "generalsCaptured": capturedRow,
    "eliminatedTurn": outTurnRow,
    "eliminatedBy": outByRow,
    "tilesTaken": takenRow,
    "tilesLost": lostRow,
    "movesMade": movesRow,
    "invalidMoves": invalidRow,
    "passes": passRow,
    "turnsPlayed": played,
    "boardW": sim.board.w,
    "boardH": sim.board.h,
    "seed": sim.config.seed,
    "policyKinds": kindRow,
    "llmTurns": llmRow,
    "fallbackTurns": fallbackRow,
    "directivesRejected": rejectedRow,
    "deadSeats": deadRow,
    "stopDetail": truncateRunes(sim.stopDetail, MaxFallbackDetailRunes)}

const ResultsKeys* = [
  "names", "aliases", "scores", "win", "winner", "reason", "endRule", "rank",
  "land", "army", "cities", "generalsCaptured", "eliminatedTurn",
  "eliminatedBy", "tilesTaken", "tilesLost", "movesMade", "invalidMoves",
  "passes", "turnsPlayed", "boardW", "boardH", "seed", "policyKinds",
  "llmTurns", "fallbackTurns", "directivesRejected", "deadSeats",
  "stopDetail"]

const SeatIndexedResultsKeys* = [
  "names", "aliases", "scores", "win", "rank", "land", "army", "cities",
  "generalsCaptured", "eliminatedTurn", "eliminatedBy", "tilesTaken",
  "tilesLost", "movesMade", "invalidMoves", "passes", "policyKinds",
  "llmTurns", "fallbackTurns", "directivesRejected", "deadSeats"]
