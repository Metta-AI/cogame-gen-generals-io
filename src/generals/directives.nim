## Plans in and out: the bounded observation a seat sees, the tolerant parse
## and per-field repair of an LLM reply, and the fixed system prompt.
##
## Forked from coworld-ctf's `src/ctf/directives.nim`. Every string that can
## reach the replay is truncated on RUNE boundaries.

import std/[json, strutils, unicode, algorithm]
import sim_types, sim_config, vision, captain, baselines

const
  SystemPrompt* = """
You command ONE ARMY on a WxH grid in a four-way war. Three other
commanders are doing the same. You cannot talk to them and you cannot see
their plans. Nobody knows who anybody is.

WHAT YOU CAN SEE
You see a tile only if you OWN it or it TOUCHES one of your tiles (all
eight directions). Everything else is fog.
- A tile you have seen before is shown from MEMORY: the terrain is what it
  was when you last looked, the owner is who held it THEN, and the army on
  it is UNKNOWN.
- A tile you have never seen is "?". You do not know what is there.
- Land, army, city counts and who is still alive are PUBLIC for everyone,
  every turn. You always know how big your rivals are. You never know
  where they are until you look.

THE BOARD
  .  plain        ^  mountain (impassable)
  o  city         *  general (a crown)
Your crown is your life. Whoever captures it takes EVERY TILE YOU OWN and
every army on them (halved), turns your crown into a city of theirs, and
you are out of the game.

THE RULES
- One move per turn. A move sends armies from a tile you own to a touching
  tile (up, down, left or right). A tile always keeps at least 1 army.
- Onto your own tile: the armies add up.
- Onto a neutral or enemy tile: if you send MORE than the army sitting
  there, you take the tile and the difference stays on it. If you send the
  same or less, the tile keeps the difference and stays theirs.
- Empty plains hold 0 army, so claiming land is nearly free. A neutral
  city holds 40 and is the only real toll on the board.
- GROWTH: every city and crown you own gains +1 army EVERY TURN. Every
  tile you own gains +1 army every 25 turns. Neutral land never grows.
  Land is production: 40 tiles is 40 free armies every 25 turns.
- All four commanders move in the same turn. Priority rotates every turn,
  so nobody has a standing advantage.

HOW YOU PLAY
You do NOT type moves. Every 8 turns you send ONE plan object and a
deterministic captain executes it, one move a turn, for the next 8 turns:
it walks your stacks along shortest paths, claims land, breaks cities,
keeps your reserve sitting on your crown, and spends the turns you allot
to walking into the fog.

WINNING
Last crown standing wins outright. If the clock runs out at turn 240 with
more than one alive, the ranking is: still alive, then who survived
longest, then most land, then biggest army, then most cities.

REPLY FORMAT
Reply with ONE JSON object and NOTHING else. Your reply MUST begin with {
and end with }. No prose, no markdown, no code fences.
{"intent":"expand|gather|attack|defend|scout|raid",
 "target":[x,y] or null,          where the effort aims
 "reserve":0,                     armies left sitting on your crown, 0-999
 "cities":"never|cheap|always",   when to spend a stack on a neutral city
 "scouts":1,                      how many of every 4 turns go scouting, 0-3
 "note":"<=160 chars for the audience watching the replay - no rival ever
         sees it"}

WHAT THE INTENTS DO
expand - your biggest stack walks to the nearest unclaimed land and takes
         it, preferring land that already touches two of your tiles.
gather - armies walk to your biggest stack, building one hammer.
attack - your biggest stack walks at `target`; with no target, at the
         nearest enemy tile you can see, else the nearest you remember.
defend - armies walk home to the crown and retake the tiles beside it.
scout  - a small party (at most 8 armies) walks into the nearest fog.
raid   - your biggest stack walks at the nearest crown you have SEEN,
         routing around visible enemy stacks bigger than itself.
Whatever the intent, if an enemy stack at least as big as your crown's
garrison appears within two tiles of your crown, the captain comes home
for six turns. You do not have to ask for that.
"""

  OperatorHeading* = "GUIDANCE FROM YOUR OPERATOR"

proc systemPromptFor*(config: GameConfig): string =
  SystemPrompt.replace("WxH", $config.boardW & " by " & $config.boardH)

# ---- the observation ----------------------------------------------------

proc terrainChar(view: SeatView, cell: int): char =
  if view.isUnknown(cell):
    return '?'
  case view.knownKind(cell)
  of ckPlain: '.'
  of ckMountain: '^'
  of ckCity: 'o'
  of ckGeneral: '*'

proc ownerChar(view: SeatView, cell: int): char =
  if view.isUnknown(cell):
    return '?'
  let owner = view.knownOwner(cell)
  if owner < 0:
    return '.'
  const upper = ['R', 'B', 'G', 'Y']
  const lower = ['r', 'b', 'g', 'y']
  if view.isVisible(cell): upper[owner] else: lower[owner]

proc sightChar(view: SeatView, cell: int): char =
  if view.isVisible(cell): '+'
  elif view.isUnknown(cell): '?'
  else: '-'

proc layerLines(view: SeatView, glyph: proc (v: SeatView, c: int): char): JsonNode =
  result = newJArray()
  for y in 0 ..< view.h:
    var line = newStringOfCap(view.w)
    for x in 0 ..< view.w:
      line.add(glyph(view, view.cellIndexOf(x, y)))
    result.add(%line)

proc cellPair(view: SeatView, cell: int): JsonNode =
  %*[view.viewX(cell), view.viewY(cell)]

proc buildObservation*(view: SeatView, config: GameConfig,
    directiveIndex, directiveCount: int, lastPlan: Plan, havePlan: bool,
    howItWent: string): JsonNode =
  ## Bounded independently of how much land is alive: three ASCII layers plus
  ## bounded structured blocks. There are no floats anywhere in it.
  var armies = newJArray()
  var armyCells: seq[int] = @[]
  for cell in 0 ..< view.viewCells():
    if view.isVisible(cell) and view.knownArmy(cell) >= 1:
      armyCells.add(cell)
  armyCells.sort(proc (a, b: int): int =
    if view.knownArmy(a) != view.knownArmy(b):
      return view.knownArmy(b) - view.knownArmy(a)
    a - b)
  var shown = 0
  for cell in armyCells:
    if shown >= MaxArmiesReported:
      break
    let owner = view.knownOwner(cell)
    armies.add(%*{
      "cell": cellPair(view, cell),
      "army": view.knownArmy(cell),
      "owner": (if owner < 0: "neutral" else: cogAlias(owner)),
      "kind": $view.knownKind(cell)})
    shown.inc

  var generals = newJArray()
  var generalCount = 0
  for cell in view.knownGenerals():
    if generalCount >= MaxKnownGenerals:
      break
    let owner = view.knownOwner(cell)
    if owner < 0:
      continue
    generals.add(%*{
      "owner": cogAlias(owner),
      "cell": cellPair(view, cell),
      "seen_turn": view.seenTurn[cell],
      "visible_now": view.isVisible(cell)})
    generalCount.inc

  var cities = newJArray()
  var cityCells: seq[int] = @[]
  for cell in 0 ..< view.viewCells():
    if view.seenTurn[cell] >= 0 and view.knownKind(cell) == ckCity:
      cityCells.add(cell)
  let home = view.generalCell
  cityCells.sort(proc (a, b: int): int =
    if home < 0:
      return a - b
    let da = abs(view.viewX(a) - view.viewX(home)) +
      abs(view.viewY(a) - view.viewY(home))
    let db = abs(view.viewX(b) - view.viewX(home)) +
      abs(view.viewY(b) - view.viewY(home))
    if da != db: da - db else: a - b)
  var cityShown = 0
  for cell in cityCells:
    if cityShown >= MaxKnownCities:
      break
    let owner = view.knownOwner(cell)
    var entry = %*{
      "cell": cellPair(view, cell),
      "owner": (if owner < 0: "neutral" else: cogAlias(owner)),
      "seen_turn": view.seenTurn[cell],
      "visible_now": view.isVisible(cell)}
    if view.isVisible(cell):
      entry["army"] = %view.knownArmy(cell)
    else:
      entry["army"] = newJNull()
    cities.add(entry)
    cityShown.inc

  var standing = newJArray()
  for seat in 0 ..< Seats:
    var entry = %*{
      "who": cogAlias(seat),
      "land": view.land[seat],
      "army": view.armyTotal[seat],
      "cities": view.cities[seat],
      "alive": view.alive[seat]}
    if not view.alive[seat]:
      entry["out_turn"] = %view.outTurn[seat]
      entry["out_to"] =
        if view.outTo[seat] >= 0: %cogAlias(view.outTo[seat])
        else: newJNull()
    standing.add(entry)

  var unknownCount = 0
  var frontier = newJArray()
  var frontierCells: seq[int] = @[]
  for cell in 0 ..< view.viewCells():
    if view.isUnknown(cell):
      unknownCount.inc
      continue
    if not view.isVisible(cell):
      continue
    for near in view.viewNeighbours8(cell):
      if view.isUnknown(near):
        frontierCells.add(cell)
        break
  let stack = view.largestOwned()
  frontierCells.sort(proc (a, b: int): int =
    if stack < 0:
      return a - b
    let da = abs(view.viewX(a) - view.viewX(stack)) +
      abs(view.viewY(a) - view.viewY(stack))
    let db = abs(view.viewX(b) - view.viewX(stack)) +
      abs(view.viewY(b) - view.viewY(stack))
    if da != db: da - db else: a - b)
  for i in 0 ..< min(MaxFrontier, frontierCells.len):
    frontier.add(cellPair(view, frontierCells[i]))

  var crown = %*{"cell": newJNull(), "army": 0, "threatened": false}
  if view.generalCell >= 0:
    crown = %*{
      "cell": cellPair(view, view.generalCell),
      "army": view.knownArmy(view.generalCell),
      "threatened": view.threatened()}

  result = %*{
    "you": cogAlias(view.seat),
    "corner": cornerOfSeat(view.seat),
    "turn": view.turn,
    "of": view.maxTurns,
    "directive_turn": directiveIndex,
    "of_directives": directiveCount,
    "growth_in": (if view.growthPeriod > 0:
        view.growthPeriod - (view.turn mod view.growthPeriod) else: 0),
    "growth_every": view.growthPeriod,
    "board": {
      "w": view.w, "h": view.h,
      "terrain": layerLines(view, terrainChar),
      "owner": layerLines(view, ownerChar),
      "sight": layerLines(view, sightChar),
      "legend": {
        "terrain": ". plain, ^ mountain, o city, * general, ? never seen",
        "owner": ". neutral, R/B/G/Y the owner NOW (visible cells), " &
          "r/b/g/y the owner WHEN LAST SEEN (remembered cells), ? never seen",
        "sight": "+ visible this turn, - remembered (army unknown), " &
          "? never seen"}},
    "your_general": crown,
    "armies": armies,
    "armies_omitted": max(0, armyCells.len - shown),
    "known_generals": generals,
    "known_cities": cities,
    "cities_omitted": max(0, cityCells.len - cityShown),
    "standing": standing,
    "fog": {"unknown_cells": unknownCount, "frontier": frontier},
    "how_it_went": truncateRunes(howItWent, MaxHowItWentRunes)}
  if havePlan:
    result["your_last_plan"] = %*{
      "intent": $lastPlan.intent,
      "target": (if lastPlan.hasTarget: %*[lastPlan.targetX, lastPlan.targetY]
                 else: newJNull()),
      "reserve": lastPlan.reserve,
      "cities": $lastPlan.cities,
      "scouts": lastPlan.scouts}
  else:
    result["your_last_plan"] = newJNull()
  discard config

# ---- parsing a reply ----------------------------------------------------

proc extractJsonObject*(text: string): string =
  ## The outermost balanced {...}, fence-tolerant, with the
  ## first-brace..last-brace rescue. Empty when nothing can be recovered.
  var body = text
  if body.len > MaxReplyBytes:
    ## Truncate the READ, on a rune boundary, before parsing.
    body = truncateRunes(body, MaxReplyBytes)
  body = body.replace("```json", " ").replace("```", " ")
  var depth = 0
  var start = -1
  var inString = false
  var escaped = false
  for i, ch in body:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      depth.inc
    of '}':
      if depth > 0:
        depth.dec
        if depth == 0 and start >= 0:
          return body[start .. i]
    else: discard
  let first = body.find('{')
  let last = body.rfind('}')
  if first >= 0 and last > first:
    return body[first .. last]
  ""

proc numberFrom(node: JsonNode, fallback: int, ok: var bool): int =
  ok = false
  if node == nil or node.kind == JNull:
    return fallback
  case node.kind
  of JInt:
    ok = true
    return int(node.getBiggestInt())
  of JFloat:
    let value = node.getFloat()
    if value == value:            ## a NaN is never finite
      ok = true
      return int(value)
    return fallback
  of JString:
    try:
      ok = true
      return parseInt(node.getStr().strip())
    except ValueError:
      ok = false
      return fallback
  else:
    return fallback

proc parsePlan*(text: string, previous: Plan, havePrevious: bool,
    repaired: var int): (Plan, bool) =
  ## Tolerant parse + per-field repair. Unknown top-level keys are ignored;
  ## a reply with a valid `note` and no usable field IS usable. Only when no
  ## JSON object at all can be recovered does this return false.
  repaired = 0
  let body = extractJsonObject(text)
  if body.len == 0:
    return (previous, false)
  var node: JsonNode
  try:
    node = parseJson(body)
  except CatchableError:
    return (previous, false)
  if node.kind != JObject:
    return (previous, false)

  var plan = if havePrevious: previous else: defaultPlanValue()
  plan.note = ""

  if node.hasKey("intent"):
    let (intent, ok) = parseIntentText(node["intent"].getStr())
    if ok: plan.intent = intent
    else:
      repaired.inc
      if not havePrevious: plan.intent = inExpand
  elif not havePrevious:
    plan.intent = inExpand

  if node.hasKey("target"):
    let target = node["target"]
    var x, y: int
    var got = false
    if target.kind == JArray and target.len >= 2:
      var okX, okY: bool
      x = numberFrom(target[0], 0, okX)
      y = numberFrom(target[1], 0, okY)
      got = okX and okY
    elif target.kind == JObject:
      var okX, okY: bool
      x = numberFrom(target{"x"}, 0, okX)
      y = numberFrom(target{"y"}, 0, okY)
      got = okX and okY
    if got:
      plan.hasTarget = true
      plan.targetX = x
      plan.targetY = y
    else:
      plan.hasTarget = false
      if target.kind != JNull:
        repaired.inc

  if node.hasKey("reserve"):
    var ok: bool
    let value = numberFrom(node["reserve"], plan.reserve, ok)
    if ok:
      let clamped = clamp(value, 0, 999)
      if clamped != value: repaired.inc
      plan.reserve = clamped
    else:
      repaired.inc

  if node.hasKey("cities"):
    let (cities, ok) = parseCityPolicyText(node["cities"].getStr())
    plan.cities = cities
    if not ok: repaired.inc

  if node.hasKey("scouts"):
    var ok: bool
    let value = numberFrom(node["scouts"], plan.scouts, ok)
    if ok:
      let clamped = clamp(value, 0, 3)
      if clamped != value: repaired.inc
      plan.scouts = clamped
    else:
      repaired.inc

  if node.hasKey("note"):
    plan.note = sanitizeNote(node["note"].getStr(), MaxNoteRunes)

  (plan, true)

proc clampPlan*(plan: Plan, w, h: int): Plan =
  ## The one place a plan's target is pinned to the board, applied to LLM and
  ## scripted plans alike so the bounded-orders test means something.
  result = plan
  result.reserve = clamp(result.reserve, 0, 999)
  result.scouts = clamp(result.scouts, 0, 3)
  result.note = truncateRunes(result.note, MaxNoteRunes)
  if result.hasTarget:
    result.targetX = clamp(result.targetX, 0, w - 1)
    result.targetY = clamp(result.targetY, 0, h - 1)

proc planJson*(plan: Plan): JsonNode =
  %*{
    "intent": $plan.intent,
    "target": (if plan.hasTarget: %*[plan.targetX, plan.targetY]
               else: newJNull()),
    "reserve": plan.reserve,
    "cities": $plan.cities,
    "scouts": plan.scouts}

proc planFromJson*(node: JsonNode): Plan =
  result = defaultPlanValue()
  if node == nil or node.kind != JObject:
    return
  let (intent, _) = parseIntentText(node{"intent"}.getStr())
  result.intent = intent
  let target = node{"target"}
  if target != nil and target.kind == JArray and target.len >= 2:
    result.hasTarget = true
    result.targetX = target[0].getInt()
    result.targetY = target[1].getInt()
  result.reserve = node{"reserve"}.getInt()
  let (cities, _) = parseCityPolicyText(node{"cities"}.getStr())
  result.cities = cities
  result.scouts = node{"scouts"}.getInt()

proc fallbackPlan*(view: SeatView): Plan =
  ## The fallback IS the sprawl baseline proc, imported and never duplicated.
  sprawlPlan(view)
