## The board as the sprite protocol sees it.
##
## Forked from coworld-ctf's `src/ctf/global.nim` — the sprite/object pools,
## the pixie compositor and the baked-floor path — with every paint, gun and
## FX family gone. `client/broadcast_core.js` is the starter's generic
## sprite/layer renderer, so this module is the whole board renderer.
##
## Three named departures from the starter, all from the design note:
##  1. the board is BAKED FLOOR ART plus per-cell chips, not per-unit sprites;
##  2. the fog is `#lightpool` in the DOM (an integer set, not a raycast), so
##     nothing here draws it;
##  3. `rig_art.nim` bakes 4x(2+1) + 4x5 chips at load and a frame is at most
##     160 blits plus the numerals.

import std/[json, strutils, tables]
import pixie

import bitworld/spriteprotocol
import sim_types, board, sim_state, sim as gensim, labels, rig_art

const
  BroadcastChromeSpriteId* = 4090
    ## The starter's reserved 1x1 never-drawn sprite whose LABEL carries the
    ## broadcast chrome JSON. Smuggling the chrome through the SAME binary
    ## channel the board rides is what makes it survive a hosted replay.
  MapLayerId* = 0
  MapBandSpriteBase* = 30
  MapBandObjectBase* = 40
  MapBandRows* = 200
  StaticBandZ* = -32768

  TintSpriteBase* = 100
  KeepNeutralSpriteId* = 140
  KeepOwnedSpriteBase* = 141
  CrownSpriteBase* = 150
  DigitSpriteBase* = 200

  TintObjectBase* = 1000
  StructureObjectBase* = 3000
  DigitObjectBase* = 12000
  MaxDigitsPerCell* = 4

  TintZ* = -100
  StructureZ* = 0
  DigitZ* = 100

type
  ViewerObject = object
    x*, y*, z*, layer*, spriteId*: int

  GlobalViewerState* = object
    ## What the client already has, so a frame emits only what changed.
    sent*: Table[int, ViewerObject]
    spritesDefined*: bool
    bandCount*: int
    ## Viewer transport commands, applied at the top of the next frame.
    replayCommands*: seq[string]
    replaySeekTick*: int
    povSlot*: int
    fogSeat*: int

proc initGlobalViewerState*(): GlobalViewerState =
  result.sent = initTable[int, ViewerObject]()
  result.replaySeekTick = -1
  result.povSlot = -1
  result.fogSeat = -1

proc applyGlobalViewerMessage*(viewer: var GlobalViewerState,
    message: string) =
  ## The client's transport commands arrive as sprite-protocol chat frames.
  for item in parseSpriteClientMessages(message):
    if item.kind != SpriteClientChatMessage:
      continue
    let text = item.text.strip()
    if text.len == 0:
      continue
    if text.startsWith("s:"):
      try:
        viewer.replaySeekTick = parseInt(text[2 .. ^1])
      except ValueError:
        discard
      continue
    if text.startsWith("v:"):
      try:
        viewer.povSlot = parseInt(text[2 .. ^1])
      except ValueError:
        discard
      continue
    viewer.replayCommands.add(text)

# ---- the bake -----------------------------------------------------------

type
  BoardArt* = object
    bands*: seq[seq[uint8]]
    bandHeights*: seq[int]
    tints*: array[Seats, array[5, seq[uint8]]]
    keepNeutral*: seq[uint8]
    keepOwned*: array[Seats, seq[uint8]]
    crowns*: array[Seats, seq[uint8]]
    digits*: array[10, seq[uint8]]
    digitW*, digitH*: int
    width*, height*: int

proc bakeBoardArt*(sim: Sim): BoardArt =
  ## One board bitmap plus the 32 pre-baked chips, at reset.
  let art = loadArt()
  let floor = bakeFloor(art, sim.board.w, sim.board.h)
  for cell in 0 ..< sim.board.cellCount():
    if sim.board.kindOf(cell) == ckMountain:
      stampMountain(floor, art, sim.board.cellX(cell), sim.board.cellY(cell))
  result.width = floor.width
  result.height = floor.height
  var y = 0
  while y < floor.height:
    let rows = min(MapBandRows, floor.height - y)
    result.bands.add(rgbaBytes(floor.subImage(0, y, floor.width, rows)))
    result.bandHeights.add(rows)
    y += rows
  for seat in 0 ..< Seats:
    for level in 0 ..< 5:
      result.tints[seat][level] = rgbaBytes(bakeTint(seat, level))
    result.keepOwned[seat] = rgbaBytes(bakeKeep(art, seat))
    result.crowns[seat] = rgbaBytes(bakeCrown(art, seat))
  result.keepNeutral = rgbaBytes(bakeKeep(art, -1))
  let sample = bakeDigit(art, 0)
  result.digitW = sample.width
  result.digitH = sample.height
  for digit in 0 .. 9:
    result.digits[digit] = rgbaBytes(bakeDigit(art, digit))

# ---- the packet ---------------------------------------------------------

proc putObject(packet: var seq[uint8], viewer: var GlobalViewerState,
    id: int, entry: ViewerObject) =
  ## The server re-describes an object only when a field differs, so an
  ## unchanged board costs no object messages at all.
  if viewer.sent.hasKey(id) and viewer.sent[id] == entry:
    return
  packet.addObject(id, entry.x, entry.y, entry.z, entry.layer, entry.spriteId)
  viewer.sent[id] = entry

proc dropObject(packet: var seq[uint8], viewer: var GlobalViewerState,
    id: int) =
  if not viewer.sent.hasKey(id):
    return
  packet.addDeleteObject(id)
  viewer.sent.del(id)

proc tintLevel(army: int): int =
  if army <= 1: 0
  elif army <= 5: 1
  elif army <= 20: 2
  elif army <= 60: 3
  else: 4

proc defineSprites(packet: var seq[uint8], art: BoardArt) =
  for band, pixels in art.bands:
    packet.addSprite(MapBandSpriteBase + band, art.width,
      art.bandHeights[band], pixels, bandLabel(band))
  for seat in 0 ..< Seats:
    for level in 0 ..< 5:
      packet.addSprite(TintSpriteBase + seat * 8 + level, CellPx, CellPx,
        art.tints[seat][level], tintLabel(seat, level))
    packet.addSprite(KeepOwnedSpriteBase + seat, CellPx, CellPx,
      art.keepOwned[seat], cityLabel(seat))
    packet.addSprite(CrownSpriteBase + seat, CellPx, CellPx,
      art.crowns[seat], crownLabel(seat))
  packet.addSprite(KeepNeutralSpriteId, CellPx, CellPx, art.keepNeutral,
    cityLabel(-1))
  for digit in 0 .. 9:
    packet.addSprite(DigitSpriteBase + digit, art.digitW, art.digitH,
      art.digits[digit], digitLabel(digit))

proc buildViewerPacket*(sim: Sim, art: BoardArt,
    viewer: var GlobalViewerState, chrome: JsonNode): seq[uint8] =
  ## One presentation frame: the layer, the viewport, the board bands (once),
  ## the changed cell chips, the numerals and the chrome JSON.
  var packet: seq[uint8] = @[]
  packet.addLayer(MapLayerId, SpriteLayerMap, SpriteLayerZoomableFlag)
  packet.addViewport(MapLayerId, art.width, art.height)
  if not viewer.spritesDefined:
    packet.defineSprites(art)
    viewer.spritesDefined = true
    viewer.bandCount = art.bands.len
  var y = 0
  for band in 0 ..< art.bands.len:
    packet.putObject(viewer, MapBandObjectBase + band, ViewerObject(
      x: 0, y: y, z: StaticBandZ, layer: MapLayerId,
      spriteId: MapBandSpriteBase + band))
    y += art.bandHeights[band]

  for cell in 0 ..< sim.board.cellCount():
    let px = sim.board.cellX(cell) * CellPx
    let py = sim.board.cellY(cell) * CellPx
    let owner = sim.board.ownerOf(cell)
    let kind = sim.board.kindOf(cell)
    let army = sim.board.armyOf(cell)

    if owner >= 0:
      packet.putObject(viewer, TintObjectBase + cell, ViewerObject(
        x: px, y: py, z: TintZ, layer: MapLayerId,
        spriteId: TintSpriteBase + owner * 8 + tintLevel(army)))
    else:
      packet.dropObject(viewer, TintObjectBase + cell)

    case kind
    of ckCity:
      packet.putObject(viewer, StructureObjectBase + cell, ViewerObject(
        x: px, y: py, z: StructureZ, layer: MapLayerId,
        spriteId: (if owner < 0: KeepNeutralSpriteId
                   else: KeepOwnedSpriteBase + owner)))
    of ckGeneral:
      packet.putObject(viewer, StructureObjectBase + cell, ViewerObject(
        x: px, y: py, z: StructureZ, layer: MapLayerId,
        spriteId: CrownSpriteBase + max(0, owner)))
    else:
      packet.dropObject(viewer, StructureObjectBase + cell)

    ## Numerals: ALWAYS the exact integer, never "T" and never "1.2k".
    var text = ""
    if army > 0 and kind != ckMountain and army <= 9999:
      text = $army
    let startX = px + (CellPx - text.len * art.digitW) div 2
    for i in 0 ..< MaxDigitsPerCell:
      let id = DigitObjectBase + cell * MaxDigitsPerCell + i
      if i < text.len:
        packet.putObject(viewer, id, ViewerObject(
          x: startX + i * art.digitW,
          y: py + CellPx - art.digitH - 2,
          z: DigitZ, layer: MapLayerId,
          spriteId: DigitSpriteBase + (ord(text[i]) - ord('0'))))
      else:
        packet.dropObject(viewer, id)

  ## The chrome rides as the label of the reserved 1x1 sprite.
  var chromePixels = newSeq[uint8](4)
  packet.addSprite(BroadcastChromeSpriteId, 1, 1, chromePixels, $chrome)
  packet
