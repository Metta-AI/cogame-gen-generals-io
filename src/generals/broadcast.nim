## The chrome JSON one presentation frame carries, the derived broadcast
## events, the lull scan and the beat timeline.
##
## Forked from coworld-ctf's `src/ctf/broadcast.nim`: `stepEvents`,
## `buildStateJson`, `rosterJson`, the lull scan, the beat timeline and the
## `lead` series keep their structure; the fields are this game's.
##
## The INHERITED keys are unchanged, because `client/chrome_common.js` is
## the starter's (plus the fleet-wide 0.5x patch) and reads them: `t`, `mt`,
## `ph`, `lob`, `sp`,
## `mx`, `st`, `lp`, `sk`, `ff`, `en`, `mm`, `teams`, `roster`, `events`,
## `lead`, `lulls`, `beats`, `over`, `pov`, `pl`.

import std/[json]
import sim_types, sim_config, board, sim_state, sim as gensim, scoring

type
  FrameContext* = object
    tick*: int
    startTick*: int
    maxTick*: int
    playing*: bool
    speed*: float
      ## What the chrome shows: 0.5 while at the replay-only half speed,
      ## else the integer multiplier.
    loop*: bool
    skipLulls*: bool
    fastForward*: bool
    transportEnabled*: bool
    mismatchTick*: int
    lobbyCountdown*: int
    lulls*: seq[(int, int)]
    beats*: seq[JsonNode]
    lead*: seq[seq[int]]
    sendSeries*: bool

proc teamKey(seat: int): string =
  teamText(teamOfSeat(seat))

proc teamsJson*(sim: Sim): JsonNode =
  result = newJObject()
  for seat in 0 ..< Seats:
    result[teamKey(seat)] = %*{
      "land": sim.stats[seat].land,
      "army": int(sim.stats[seat].army),
      "cities": sim.stats[seat].cities,
      "alive": sim.stats[seat].alive,
      "out": sim.stats[seat].eliminatedTurn,
      "fallbacks": sim.stats[seat].fallbackTurns,
      "lives": (if sim.stats[seat].alive: 1 else: 0),
      "policies": %[sim.names[seat]]}

proc rosterJson*(sim: Sim): JsonNode =
  ## Spectator side ONLY: `name` is the real policy name. A seat never sees
  ## this object; in-game it is `RED-alpha` and nothing else.
  result = newJArray()
  for seat in 0 ..< Seats:
    result.add(%*{
      "s": seat,
      "seat": seat,
      "team": teamKey(seat),
      "name": sim.names[seat],
      "pol": sim.names[seat],
      "alias": cogAlias(seat),
      "col": teamKey(seat),
      "alive": sim.stats[seat].alive,
      "lives": (if sim.stats[seat].alive: 1 else: 0),
      "kind": sim.policyKinds[seat]})

proc cellsJson*(sim: Sim, previous: var seq[int], full: bool): JsonNode =
  ## A delta: the full array on the first frame and on every keyframe, and
  ## only the cells whose kind, owner or army changed after that.
  result = newJArray()
  let cells = sim.board.cellCount()
  if previous.len != cells * 3:
    previous = newSeq[int](cells * 3)
    for i in 0 ..< cells:
      previous[i * 3] = -9
  for cell in 0 ..< cells:
    let kind = int(sim.board.kind[cell])
    let owner = sim.board.ownerOf(cell)
    let army = sim.board.armyOf(cell)
    if full or previous[cell * 3] != kind or previous[cell * 3 + 1] != owner or
        previous[cell * 3 + 2] != army:
      result.add(%*{"i": cell, "k": $sim.board.kindOf(cell),
        "o": owner, "a": army})
      previous[cell * 3] = kind
      previous[cell * 3 + 1] = owner
      previous[cell * 3 + 2] = army

proc planJsonRow(sim: Sim, seat: int): JsonNode =
  %*{"seat": seat, "turn": sim.planTurn[seat],
     "intent": $sim.plan[seat].intent,
     "source": $sim.planSource[seat],
     "note": sim.plan[seat].note}

proc buildStateJson*(sim: Sim, context: FrameContext,
    previousCells: var seq[int], fullCells: bool): JsonNode =
  let phaseText =
    case sim.phase
    of phLobby: "lobby"
    of phPlaying: "playing"
    of phGameOver: "gameover"
  var landRow = newJArray()
  var armyRow = newJArray()
  var cityRow = newJArray()
  var aliveRow = newJArray()
  var outRow = newJArray()
  var outByRow = newJArray()
  var generalRow = newJArray()
  var plans = newJArray()
  for seat in 0 ..< Seats:
    landRow.add(%sim.stats[seat].land)
    armyRow.add(%int(sim.stats[seat].army))
    cityRow.add(%sim.stats[seat].cities)
    aliveRow.add(%sim.stats[seat].alive)
    outRow.add(%sim.stats[seat].eliminatedTurn)
    outByRow.add(%sim.stats[seat].eliminatedBy)
    generalRow.add(%sim.board.generalCell[seat])
    if sim.stats[seat].alive and sim.planTurn[seat] >= 0:
      plans.add(planJsonRow(sim, seat))

  result = %*{
    "t": context.tick,
    "mt": sim.config.maxTurns,
    "st": context.startTick,
    "mx": max(context.maxTick, context.startTick + 1),
    "ph": phaseText,
    "lob": context.lobbyCountdown,
    "sp": context.speed,
    "pl": context.playing,
    "lp": context.loop,
    "sk": context.skipLulls,
    "ff": context.fastForward,
    "en": context.transportEnabled,
    "mm": context.mismatchTick,
    "pov": -1,
    "bs": 1,
    "teams": teamsJson(sim),
    "roster": rosterJson(sim),
    "events": sim.frameEvents,
    "turn": sim.turn,
    "turns": sim.config.maxTurns,
    "growthEvery": sim.config.growthPeriod,
    "growthIn": (if sim.config.growthPeriod > 0:
        sim.config.growthPeriod - (sim.turn mod sim.config.growthPeriod)
      else: 0),
    "w": sim.board.w,
    "h": sim.board.h,
    "cells": cellsJson(sim, previousCells, fullCells),
    "gen": generalRow,
    "alive": aliveRow,
    "stand": {"land": landRow, "army": armyRow, "cities": cityRow},
    "out": outRow,
    "outBy": outByRow,
    "plan": plans}

  if context.sendSeries:
    var lead = newJArray()
    for row in context.lead:
      var point = newJArray()
      for value in row:
        point.add(%value)
      lead.add(point)
    result["lead"] = %*{
      "teams": ["red", "blue", "green", "yellow"],
      "pts": lead}
    var lulls = newJArray()
    for span in context.lulls:
      lulls.add(%*[span[0] + context.startTick, span[1] + context.startTick])
    result["lulls"] = lulls
    var beats = newJArray()
    for beat in context.beats:
      var node = copy(beat)
      node["t"] = %(beat{"t"}.getInt() + context.startTick)
      beats.add(node)
    result["beats"] = beats

  if sim.phase == phGameOver:
    let scores = sim.rankSeats(sim.turnsPlayed())
    let winner = winnerSeat(scores)
    var rankRow = newJArray()
    for seat in 0 ..< Seats:
      rankRow.add(%scores[seat].rank)
    result["over"] = %*{
      "winner": (if winner >= 0: teamKey(winner) else: ""),
      "draw": winner < 0,
      "t": context.tick,
      "reason": sim.reason,
      "endRule": sim.endRule,
      "rank": rankRow,
      "land": landRow}

proc isLullTurn*(events: JsonNode): bool =
  ## A lull is a stretch with no citytaken / generalspotted /
  ## generalcaptured / growth event.
  for event in events:
    case event{"k"}.getStr()
    of "citytaken", "generalspotted", "generalcaptured", "growth":
      return false
    else: discard
  true
