## The tier-2 analysis stream: `COGAME_EVENTS_URI` gets these as JSON lines
## with the mandatory trailing summary row. Forked from coworld-ctf's
## `src/ctf/events.nim`; only the `SimEventKind` members are this game's.

import std/[json, strutils]
import sim_types

type
  SimEventKind* = enum
    sePhaseChange = "phase"
    seGrowth = "growth"
    seClaim = "claim"
    seCityTaken = "citytaken"
    seTileLost = "tilelost"
    seStackClash = "stackclash"
    seGeneralSpotted = "generalspotted"
    seGeneralCaptured = "generalcaptured"
    seEliminated = "eliminated"
    sePlan = "plan"
    seFallback = "fallback"
    seEnd = "end"

  SimEvent* = object
    turn*: int
    kind*: SimEventKind
    fields*: JsonNode

  EventBuffer* = object
    records*: seq[SimEvent]

proc emit*(buffer: var EventBuffer, turn: int, kind: SimEventKind,
    fields: JsonNode) =
  buffer.records.add(SimEvent(turn: turn, kind: kind, fields: fields))

proc toJson*(buffer: EventBuffer): JsonNode =
  result = newJArray()
  for record in buffer.records:
    var node = newJObject()
    node["t"] = %record.turn
    node["k"] = %($record.kind)
    for key, value in record.fields:
      node[key] = value
    result.add(node)

proc eventsJsonl*(buffer: EventBuffer, ticks: int): string =
  ## One JSON object per line plus the mandatory summary row.
  var lines: seq[string] = @[]
  for record in buffer.records:
    var node = newJObject()
    node["type"] = %($record.kind)
    node["t"] = %record.turn
    for key, value in record.fields:
      node[key] = value
    lines.add($node)
  lines.add($ %*{
    "type": "summary", "ticks": ticks,
    "events": buffer.records.len, "gameVersion": GameVersion
  })
  lines.join("\n") & "\n"
