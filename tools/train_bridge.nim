## Persistent numeric decision bridge over the native GEN Generals.io simulator.

import std/[json, os]
import generals/[sim, decide, llm]

const
  Variants = ["ffa", "blitz", "citadels"]
  Reserves = [0, 10, 20, 40, 80, 160, 320, 999]
  MaxW = 16
  MaxH = 10

var
  game: Sim
  seats: seq[int]
  cursor: int
  decisionId: int
  actions: array[Seats, JsonNode]
  lastLand, lastArmy, lastCities: array[Seats, int]
  variant: string

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc options(width: int): JsonNode =
  result = newJArray()
  for value in 0 ..< width:
    result.add(%value)

proc heads(): JsonNode =
  %*[
    {"name": "intent", "choices": ["expand", "gather", "attack",
      "defend", "scout", "raid"]},
    {"name": "target_enabled", "choices": [0, 1]},
    {"name": "x", "choices": options(game.board.w)},
    {"name": "y", "choices": options(game.board.h)},
    {"name": "reserve", "choices": Reserves},
    {"name": "cities", "choices": ["never", "cheap", "always"]},
    {"name": "scouts", "choices": [0, 1, 2, 3]}
  ]

proc seatObservation(seat: int): JsonNode =
  let view = game.viewOf(seat)
  buildObservation(view, game.config, game.directiveIndex(),
    game.directiveCount(), game.plan[seat], game.havePlan[seat],
    game.howItWent(seat, lastLand[seat], lastArmy[seat], lastCities[seat]))

proc currentDecision(): JsonNode =
  let seat = seats[cursor]
  let observation = seatObservation(seat)
  let system = systemPromptFor(game.config)
  let user = userMessage("", $observation)
  var properties = newJObject()
  for head in heads():
    properties[head["name"].getStr()] = %*{"enum": head["choices"]}
  %*{"kind": "decision", "game": "gen-generals-io",
    "decision_id": decisionId, "seat": seat, "engine_seat": seat,
    "turn": game.turn, "semantic_view": observation,
    "inbox": [], "messages": [
      {"role": "system", "content": system},
      {"role": "user", "content": user}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": properties,
      "required": ["intent", "target_enabled", "x", "y", "reserve",
        "cities", "scouts"]}, "typed_question": newJNull()}

proc encoding(): JsonNode =
  let seat = seats[cursor]
  let view = game.viewOf(seat)
  var values = newJArray()
  for name in Variants:
    values.add(%(if variant == name: 1 else: 0))
  for other in 0 ..< Seats:
    values.add(%(if seat == other: 1 else: 0))
  values.add(%(float(game.turn) / float(game.config.maxTurns)))
  values.add(%(float(view.w) / float(MaxW)))
  values.add(%(float(view.h) / float(MaxH)))
  for other in 0 ..< Seats:
    values.add(%(if view.alive[other]: 1 else: 0))
    values.add(%(float(view.land[other]) / float(MaxW * MaxH)))
    values.add(%(float(view.armyTotal[other]) / 10000.0))
    values.add(%(float(view.cities[other]) / 16.0))
  for y in 0 ..< MaxH:
    for x in 0 ..< MaxW:
      if x >= view.w or y >= view.h:
        for field in 0 ..< 5: values.add(%0)
        continue
      let cell = view.cellIndexOf(x, y)
      let known = not view.isUnknown(cell)
      values.add(%(if view.isVisible(cell): 1 else: 0))
      values.add(%(if view.isRemembered(cell): 1 else: 0))
      values.add(%(if known: float(ord(view.knownKind(cell)) + 1) / 4.0
        else: 0.0))
      values.add(%(if known: float(view.knownOwner(cell) + 1) /
        float(Seats) else: 0.0))
      values.add(%(float(min(view.knownArmy(cell), 1000)) / 1000.0))
  values.add(%(if game.havePlan[seat]: 1 else: 0))
  values.add(%(float(ord(game.plan[seat].intent)) / 5.0))
  values.add(%(if game.plan[seat].hasTarget: 1 else: 0))
  values.add(%(float(game.plan[seat].targetX) / float(MaxW)))
  values.add(%(float(game.plan[seat].targetY) / float(MaxH)))
  values.add(%(float(game.plan[seat].reserve) / 999.0))
  values.add(%(float(ord(game.plan[seat].cities)) / 2.0))
  values.add(%(float(game.plan[seat].scouts) / 3.0))
  doAssert values.len == 834
  %*{"decision_id": decisionId, "values": values,
    "action_heads": heads()}

proc reset(request: JsonNode, manifestPath: string): JsonNode =
  doAssert request["players"].getInt() == Seats
  let manifest = parseFile(manifestPath)
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  variantConfig["seed"] = %seedOf(request["seed"].getStr())
  var config = defaultGameConfig()
  config.update($variantConfig)
  game = initSim(config)
  game.phase = phPlaying
  game.gameStartTick = config.startWaitTicks
  seats = game.aliveSeats()
  cursor = 0
  decisionId = 0
  lastLand = [0, 0, 0, 0]
  lastArmy = [0, 0, 0, 0]
  lastCities = [0, 0, 0, 0]
  currentDecision()

proc teacher(): JsonNode =
  let seat = seats[cursor]
  let plan = scriptedDecision(game, seat, skSprawl).plan
  %*{"response": $(%*{
    "intent": $plan.intent,
    "target_enabled": (if plan.hasTarget: 1 else: 0),
    "x": (if plan.hasTarget: plan.targetX else: 0),
    "y": (if plan.hasTarget: plan.targetY else: 0),
    "reserve": plan.reserve, "cities": $plan.cities,
    "scouts": plan.scouts})}

proc step(request: JsonNode): JsonNode =
  doAssert request["decision_id"].getInt() == decisionId
  let action = parseJson(request["response"].getStr())
  for head in heads():
    let name = head["name"].getStr()
    doAssert action[name] in head["choices"], "action is masked: " & name
  actions[seats[cursor]] = action
  inc cursor
  inc decisionId
  if cursor == seats.len:
    for seat in seats:
      let action = actions[seat]
      let plan = planFromJson(%*{
        "intent": action["intent"],
        "target": (if action["target_enabled"].getInt() == 1:
          %*[action["x"], action["y"]] else: newJNull()),
        "reserve": action["reserve"], "cities": action["cities"],
        "scouts": action["scouts"], "note": ""})
      game.installPlan(seat, plan, psScripted, 0)
    for seat in 0 ..< Seats:
      lastLand[seat] = game.stats[seat].land
      lastArmy[seat] = int(game.stats[seat].army)
      lastCities[seat] = game.stats[seat].cities
    game.stepTurn()
    while not game.done and not game.isDirectiveTurn():
      game.stepTurn()
    seats = game.aliveSeats()
    cursor = 0
  let observation = if game.done:
    let ranks = game.rankSeats(game.turnsPlayed())
    var scores = newJObject()
    var utilities = newJObject()
    for seat in 0 ..< Seats:
      let score = float(Seats - 1 - ranks[seat].rank) / float(Seats - 1)
      scores[$seat] = %score
      utilities[$seat] = %(2.0 * score - 1.0)
    %*{"kind": "terminal", "scores": scores,
      "utilities": utilities}
  else: currentDecision()
  %*{"kind": "accepted", "action": action,
    "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    quit("usage: gen-generals-train-bridge MANIFEST VARIANT", 1)
  let manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in Variants
  for line in stdin.lines:
    let request = parseJson(line)
    let response = case request["kind"].getStr()
      of "reset": reset(request, manifestPath)
      of "encode": encoding()
      of "teacher": teacher()
      of "step": step(request)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
