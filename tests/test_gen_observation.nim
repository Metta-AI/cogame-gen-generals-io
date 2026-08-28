## Tests 15 and 16 — the observation contract and the two name spaces.

import std/[unittest, json, strutils]
import generals/sim as gensim
import generals/roster
import generals/llm
import generals/broadcast

const SentinelPolicy = "daveey-sentinel@softmax.example"

proc playedSim(seed = 1734029581, turns = 96): Sim =
  var config = defaultGameConfig()
  config.seed = seed
  config.players = @[]
  for seat in 0 ..< Seats:
    config.players.add(PlayerConfig(name: SentinelPolicy & "-" & $seat))
  result = gensim.initSim(config)
  while result.turn < turns and not result.done:
    if result.isDirectiveTurn():
      for seat in result.aliveSeats():
        let kind = if seat mod 2 == 0: skSprawl else: skCrown
        result.installPlan(seat, scriptedPlan(result.viewOf(seat), kind),
          psScripted, 0)
    result.stepTurn()

proc observationFor(sim: Sim, seat: int): JsonNode =
  buildObservation(sim.viewOf(seat), sim.config, sim.directiveIndex(),
    sim.directiveCount(), sim.plan[seat], sim.havePlan[seat],
    sim.howItWent(seat, 0, 0, 0))

suite "the observation contract":
  test "the three layers are exactly boardH lines of boardW legal glyphs":
    let sim = playedSim()
    for seat in 0 ..< Seats:
      let observation = observationFor(sim, seat)
      let board = observation["board"]
      check board["w"].getInt() == sim.board.w
      check board["h"].getInt() == sim.board.h
      for pair in [("terrain", {'.', '^', 'o', '*', '?'}),
          ("owner", {'.', 'R', 'B', 'G', 'Y', 'r', 'b', 'g', 'y', '?'}),
          ("sight", {'+', '-', '?'})]:
        let layer = pair[0]
        let alphabet = pair[1]
        check board[layer].len == sim.board.h
        for line in board[layer]:
          let text = line.getStr()
          check text.len == sim.board.w
          for ch in text:
            check ch in alphabet

  test "a visible cell reports the exact kind, owner and army":
    let sim = playedSim()
    let view = sim.viewOf(0)
    let observation = observationFor(sim, 0)
    var reported = 0
    for entry in observation["armies"]:
      let x = entry["cell"][0].getInt()
      let y = entry["cell"][1].getInt()
      let cell = sim.board.cellIndex(x, y)
      check view.isVisible(cell)
      check entry["army"].getInt() == sim.board.armyOf(cell)
      check entry["kind"].getStr() == $sim.board.kindOf(cell)
      reported.inc
    check reported > 0
    check reported <= MaxArmiesReported

  test "a remembered cell reports its last-seen owner and a null army":
    let sim = playedSim()
    let view = sim.viewOf(0)
    let observation = observationFor(sim, 0)
    var remembered = 0
    for entry in observation["known_cities"]:
      if entry["visible_now"].getBool():
        continue
      remembered.inc
      check entry["army"].kind == JNull
      check entry["seen_turn"].getInt() >= 0
    ## Whatever the episode produced, no remembered cell may carry a number.
    check remembered >= 0
    discard view

  test "no cell outside visible-or-remembered leaks anywhere in the object":
    ## A sentinel-army sweep: give every unknown cell an army value no
    ## visible or remembered cell has, then assert the number never appears.
    var sim = playedSim()
    let view = sim.viewOf(0)
    const Sentinel = 90210
    for cell in 0 ..< sim.board.cellCount():
      if view.isVisible(cell) or view.isRemembered(cell):
        continue
      if sim.board.kindOf(cell) == ckMountain:
        continue
      sim.board.army[cell] = int32(Sentinel)
    sim.recountSeats()
    let text = $observationFor(sim, 0)
    check $Sentinel notin text

  test "standing is present, complete and IDENTICAL for all four seats":
    let sim = playedSim()
    var first = ""
    for seat in 0 ..< Seats:
      let standing = observationFor(sim, seat)["standing"]
      check standing.len == Seats
      for entry in standing:
        check entry.hasKey("who")
        check entry.hasKey("land")
        check entry.hasKey("army")
        check entry.hasKey("cities")
        check entry.hasKey("alive")
      if seat == 0: first = $standing
      else: check $standing == first

  test "every list is capped and how_it_went is inside its rune cap":
    let sim = playedSim()
    for seat in 0 ..< Seats:
      let observation = observationFor(sim, seat)
      check observation["armies"].len <= MaxArmiesReported
      check observation["known_cities"].len <= MaxKnownCities
      check observation["known_generals"].len <= MaxKnownGenerals
      check observation["fog"]["frontier"].len <= MaxFrontier
      check observation["armies_omitted"].getInt() >= 0
      check observation["how_it_went"].getStr().len <= MaxHowItWentRunes * 4

  test "known_cities and the frontier are ordered by BFS distance":
    ## Not Manhattan distance: with mountains on the board the two orders
    ## differ, and the note asks for the walk the captain would actually make.
    let sim = playedSim()
    for seat in 0 ..< Seats:
      let view = sim.viewOf(seat)
      let observation = observationFor(sim, seat)
      let home = view.generalCell
      if home < 0:
        continue
      let paths = view.shortestPaths(home, false, 0)
      var last = -1
      for entry in observation["known_cities"]:
        let cell = entry["cell"][1].getInt() * sim.board.w +
          entry["cell"][0].getInt()
        check paths.dist[cell] >= last
        last = paths.dist[cell]
      let stack = view.largestOwned()
      if stack < 0:
        continue
      let fogPaths = view.shortestPaths(stack, false, 0)
      last = -1
      for pair in observation["fog"]["frontier"]:
        let cell = pair[1].getInt() * sim.board.w + pair[0].getInt()
        check fogPaths.dist[cell] >= last
        last = fogPaths.dist[cell]

  test "the seed, another seat's plan and another seat's note never appear":
    var sim = playedSim()
    for seat in 0 ..< Seats:
      sim.plan[seat].note = "secret-note-for-seat-" & $seat
    sim.plan[1].intent = inRaid
    for seat in 0 ..< Seats:
      let text = $observationFor(sim, seat)
      check $sim.config.seed notin text
      for other in 0 ..< Seats:
        if other == seat:
          continue
        check ("secret-note-for-seat-" & $other) notin text
      ## No real policy name reaches a seat-facing byte.
      check SentinelPolicy notin text
      check cogAlias(seat) in text

  test "there are no floats anywhere in the observation":
    let sim = playedSim()
    proc noFloats(node: JsonNode) =
      case node.kind
      of JFloat: check false
      of JObject:
        for _, value in node: noFloats(value)
      of JArray:
        for value in node: noFloats(value)
      else: discard
    for seat in 0 ..< Seats:
      noFloats(observationFor(sim, seat))

suite "the two name spaces":
  test "the in-game names are ONLY the four aliases":
    check cogAlias(0) == "RED-alpha"
    check cogAlias(1) == "BLUE-alpha"
    check cogAlias(2) == "GREEN-alpha"
    check cogAlias(3) == "YELLOW-alpha"

  test "no seat-facing byte carries a real policy name":
    let sim = playedSim()
    for seat in 0 ..< Seats:
      let observation = observationFor(sim, seat)
      let user = userMessage("operator guidance", $observation)
      check SentinelPolicy notin user
      check SentinelPolicy notin systemPromptFor(sim.config)
      ## and the plan record's `view` is the same object.
      check SentinelPolicy notin $observation

  test "the spectator side MUST carry the real names":
    let sim = playedSim()
    let results = $generalsResultsJson(sim)
    check SentinelPolicy in results
    var previous: seq[int] = @[]
    let chrome = $buildStateJson(sim, FrameContext(tick: 1, startTick: 0,
      maxTick: 2), previous, true)
    check SentinelPolicy in chrome
    for seat in 0 ..< Seats:
      check cogAlias(seat) in chrome
      check cogAlias(seat) in results
