## Test 16 — the two name spaces, asserted from BOTH sides.
##
## The starter's identity-privacy test, kept and extended: no seat frame, no
## LLM system-or-user message and no plan record's `view` may contain a
## sentinel policy address, while the broadcast stream, `roster[].name`, the
## DOM scorebug and `results.names` MUST contain it.

import std/[unittest, json, strutils]
import generals/sim as gensim
import generals/broadcast
import generals/llm
import generals/roster

const Sentinel = "daveey_sentinel@softmax.example"

proc seatFrame(sim: Sim, seat: int): string =
  ## Byte for byte what `server.nim`'s `pushSeatFrames` sends a seat.
  $ %*{
    "type": "turn",
    "protocol": "gen-generals-io.player.v1",
    "turn": sim.turn,
    "of": sim.config.maxTurns,
    "you": cogAlias(seat),
    "alive": sim.stats[seat].alive}

proc playedSim(): Sim =
  var config = defaultGameConfig()
  config.players = @[]
  for seat in 0 ..< Seats:
    config.players.add(PlayerConfig(name: Sentinel & $seat))
  result = gensim.initSim(config)
  for seat in 0 ..< Seats:
    result.policies[seat] = Sentinel & $seat
    result.policyKinds[seat] = if seat < 2: "llm" else: "scripted"
  while result.turn < 64 and not result.done:
    if result.isDirectiveTurn():
      for seat in result.aliveSeats():
        result.installPlan(seat, sprawlPlan(result.viewOf(seat)),
          psScripted, 0)
    result.stepTurn()

suite "identity privacy":
  test "no seat frame carries a policy address":
    let sim = playedSim()
    for seat in 0 ..< Seats:
      let frame = seatFrame(sim, seat)
      check Sentinel notin frame
      check cogAlias(seat) in frame

  test "no LLM system or user message carries a policy address":
    let sim = playedSim()
    check Sentinel notin systemPromptFor(sim.config)
    for seat in 0 ..< Seats:
      let observation = buildObservation(sim.viewOf(seat), sim.config,
        sim.directiveIndex(), sim.directiveCount(), sim.plan[seat],
        sim.havePlan[seat], sim.howItWent(seat, 0, 0, 0))
      let user = userMessage("guidance from the operator", $observation)
      check Sentinel notin user
      ## The plan record's `view` IS this object.
      check Sentinel notin $observation

  test "the broadcast stream and the results MUST carry it":
    let sim = playedSim()
    var previous: seq[int] = @[]
    let chrome = buildStateJson(sim, FrameContext(tick: 5, startTick: 0,
      maxTick: 10), previous, true)
    check Sentinel in $chrome
    for entry in chrome["roster"]:
      check Sentinel in entry["name"].getStr()
      check entry["alias"].getStr() == cogAlias(entry["s"].getInt())
    let results = generalsResultsJson(sim)
    for name in results["names"]:
      check Sentinel in name.getStr()
    for seat in 0 ..< Seats:
      check results["aliases"][seat].getStr() == cogAlias(seat)

  test "showPlayerLabels is false, so the board never labels a seat":
    let sim = playedSim()
    check not sim.config.showPlayerLabels

  test "a seat can never learn which policy holds a rival seat":
    let sim = playedSim()
    for seat in 0 ..< Seats:
      let observation = buildObservation(sim.viewOf(seat), sim.config,
        sim.directiveIndex(), sim.directiveCount(), sim.plan[seat],
        sim.havePlan[seat], sim.howItWent(seat, 0, 0, 0))
      for entry in observation["standing"]:
        let who = entry["who"].getStr()
        var known = false
        for other in 0 ..< Seats:
          if who == cogAlias(other):
            known = true
        check known
      check "llm" notin $observation
      check "scripted" notin $observation
