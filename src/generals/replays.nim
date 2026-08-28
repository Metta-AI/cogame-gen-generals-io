## The `COWLDGEN` binary replay codec.
##
## Forked from coworld-ctf's `src/ctf/replays.nim`: magic + format version +
## game name/version header, the resolved config JSON, then the record
## stream - joins, the plan INPUT records (load-bearing, re-applied before
## the turn they belong to is stepped), the presentation chat records, and
## one `gameHash` per tick.
##
## The board is re-derived from the seed rather than stored: it is in
## `gameHash` from turn 0, so a divergence surfaces immediately, and the file
## stays around 75 KB.

import std/[json]
import sim_types

const
  ReplayMagic* = "COWLDGEN"
  ReplayFormatVersion* = 1
  ReplayKeyframeTicks* = 100

  RecJoin* = 1'u8
  RecPlan* = 2'u8
  RecChat* = 3'u8
  RecHash* = 4'u8
  RecLeave* = 5'u8

type
  ReplayRecord* = object
    kind*: uint8
    tick*: int
    hash*: uint32
    payload*: JsonNode

  ReplayData* = object
    formatVersion*: int
    gameName*: string
    gameVersion*: string
    config*: JsonNode
    records*: seq[ReplayRecord]

  ReplayWriter* = object
    body*: string
    header*: string
    started*: bool

proc putU16(buffer: var string, value: int) =
  buffer.add(char((value shr 8) and 0xFF))
  buffer.add(char(value and 0xFF))

proc putU32(buffer: var string, value: uint32) =
  buffer.add(char(int((value shr 24) and 0xFF'u32)))
  buffer.add(char(int((value shr 16) and 0xFF'u32)))
  buffer.add(char(int((value shr 8) and 0xFF'u32)))
  buffer.add(char(int(value and 0xFF'u32)))

proc readU16(data: string, offset: var int): int =
  if offset + 2 > data.len:
    raise newException(GenError, "truncated replay")
  result = (int(uint8(data[offset])) shl 8) or int(uint8(data[offset + 1]))
  offset += 2

proc readU32(data: string, offset: var int): uint32 =
  if offset + 4 > data.len:
    raise newException(GenError, "truncated replay")
  result = (uint32(uint8(data[offset])) shl 24) or
    (uint32(uint8(data[offset + 1])) shl 16) or
    (uint32(uint8(data[offset + 2])) shl 8) or
    uint32(uint8(data[offset + 3]))
  offset += 4

proc initReplayWriter*(config: JsonNode): ReplayWriter =
  result.header = ReplayMagic
  result.header.putU16(ReplayFormatVersion)
  result.header.putU16(GameName.len)
  result.header.add(GameName)
  result.header.putU16(GameVersion.len)
  result.header.add(GameVersion)
  let text = $config
  result.header.putU32(uint32(text.len))
  result.header.add(text)
  result.started = true

proc writeRecord(writer: var ReplayWriter, kind: uint8, payload: string) =
  writer.body.add(char(kind))
  writer.body.putU32(uint32(payload.len))
  writer.body.add(payload)

proc writeJoin*(writer: var ReplayWriter, seat: int, name, token: string) =
  writer.writeRecord(RecJoin,
    $ %*{"seat": seat, "name": name, "slot": seat, "token": token})

proc writeLeave*(writer: var ReplayWriter, seat: int) =
  writer.writeRecord(RecLeave, $ %*{"seat": seat})

proc writePlanInput*(writer: var ReplayWriter, turn, seat: int,
    plan: JsonNode) =
  ## THE input log of this game: load-bearing, applied before the turn is
  ## stepped, on both the recording and the playback side.
  var node = %*{"turn": turn, "seat": seat}
  for key, value in plan:
    node[key] = value
  writer.writeRecord(RecPlan, $node)

proc writeChat*(writer: var ReplayWriter, kind: string, fields: JsonNode) =
  var node = %*{"k": kind}
  for key, value in fields:
    node[key] = value
  writer.writeRecord(RecChat, $node)

proc writeHash*(writer: var ReplayWriter, tick: int, hash: uint32) =
  var payload = ""
  payload.putU32(uint32(tick))
  payload.putU32(hash)
  writer.writeRecord(RecHash, payload)

proc bytes*(writer: ReplayWriter): string =
  writer.header & writer.body

proc parseReplayBytes*(data: string): ReplayData =
  if data.len < ReplayMagic.len or
      data[0 ..< ReplayMagic.len] != ReplayMagic:
    raise newException(GenError, "not a " & ReplayMagic & " replay")
  var offset = ReplayMagic.len
  result.formatVersion = readU16(data, offset)
  if result.formatVersion != ReplayFormatVersion:
    raise newException(GenError,
      "unsupported replay format version " & $result.formatVersion)
  let nameLen = readU16(data, offset)
  result.gameName = data[offset ..< offset + nameLen]
  offset += nameLen
  let versionLen = readU16(data, offset)
  result.gameVersion = data[offset ..< offset + versionLen]
  offset += versionLen
  let configLen = int(readU32(data, offset))
  if offset + configLen > data.len:
    raise newException(GenError, "truncated replay config")
  result.config = parseJson(data[offset ..< offset + configLen])
  offset += configLen
  while offset < data.len:
    let kind = uint8(data[offset])
    offset.inc
    let length = int(readU32(data, offset))
    if offset + length > data.len:
      raise newException(GenError, "truncated replay record")
    let payload = data[offset ..< offset + length]
    offset += length
    var record = ReplayRecord(kind: kind)
    if kind == RecHash:
      var inner = 0
      record.tick = int(readU32(payload, inner))
      record.hash = readU32(payload, inner)
    else:
      record.payload = parseJson(payload)
      if record.payload.hasKey("turn"):
        record.tick = record.payload["turn"].getInt()
    result.records.add(record)

proc planRecords*(replay: ReplayData): seq[ReplayRecord] =
  for record in replay.records:
    if record.kind == RecPlan:
      result.add(record)

proc chatRecords*(replay: ReplayData, kind: string): seq[JsonNode] =
  for record in replay.records:
    if record.kind == RecChat and record.payload{"k"}.getStr() == kind:
      result.add(record.payload)

proc hashAt*(replay: ReplayData, tick: int): (uint32, bool) =
  for record in replay.records:
    if record.kind == RecHash and record.tick == tick:
      return (record.hash, true)
  (0'u32, false)

proc joinNames*(replay: ReplayData): seq[string] =
  for record in replay.records:
    if record.kind == RecJoin:
      result.add(record.payload{"name"}.getStr())

proc replaySummaryText*(replay: ReplayData): string =
  ## A one-line human summary, used by the native diagnostics tools.
  "replay " & replay.gameName & " v" & replay.gameVersion & " with " &
    $replay.records.len & " records"
