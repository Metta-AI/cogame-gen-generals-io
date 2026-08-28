## The chip compositor: every drawable this game has, baked ONCE at load by
## pixie out of the starter's shipped art.
##
## Forked from coworld-ctf's `src/ctf/rig_art.nim`. Real art, no
## placeholders, no downloads: the floor is `data/arena_floor.png` tiled and
## darkened with a chalk grid, mountains are stamped from
## `client/art/walls/wall_{h,v}.jpg`, city keeps are those wall textures
## tinted through the team colours, crowns are
## `data/soldier_{red,blue,green,yellow}_crown.png`, and numerals are set in
## `data/atlas/nes-pixel.ttf`.

import std/[os]
import pixie
import sim_types

const
  CellPx* = 40
  DigitH* = 14
  TintLevels* = 5

  TeamColors*: array[Seats, array[3, int]] = [
    [224, 82, 58],      # red    #e0523a
    [63, 124, 196],     # blue   #3f7cc4
    [69, 168, 94],      # green  #45a85e
    [221, 197, 49]      # yellow #ddc531
  ]

type
  ArtPack* = object
    floorTile*: Image
    wallH*, wallV*: Image
    crowns*: array[Seats, Image]
    typeface*: Typeface
    ok*: bool

proc appDirOrEmpty(): string =
  ## `getAppDir` reads /proc/self/exe. Under emscripten that readlink fails
  ## and Nim raises a DEFECT out of `getApplAux` -- not a CatchableError, so
  ## no try/except in the caller can hold it, and the whole replay load dies
  ## with "value out of range: -1". The bundle never needs an app dir: its
  ## assets are preloaded at a relative path. So do not ask for one there.
  when defined(emscripten):
    ""
  else:
    try:
      getAppDir()
    except CatchableError:
      ""

proc dataDir*(): string =
  ## The wasm bundle preloads `data@data`, so the relative path wins there;
  ## the native container copies `data/` next to the binary.
  let appDir = appDirOrEmpty()
  var candidates = @["data"]
  if appDir.len > 0:
    candidates.add(appDir / "data")
    candidates.add(appDir / ".." / "data")
  for candidate in candidates:
    if dirExists(candidate):
      return candidate
  "data"

proc clientArtDir*(): string =
  ## `Dockerfile.replay-viewer` preloads `client/art@art`, so the bundle sees
  ## it as "art"; the native image keeps the repo layout.
  let appDir = appDirOrEmpty()
  var candidates = @["client/art", "art"]
  if appDir.len > 0:
    candidates.add(appDir / "client" / "art")
  for candidate in candidates:
    if dirExists(candidate):
      return candidate
  "art"

proc loadArt*(): ArtPack =
  ## Best effort: a missing asset degrades to a flat tone rather than
  ## crashing the viewer, and `ok` says which happened.
  result.ok = true
  let data = dataDir()
  let art = clientArtDir()
  try:
    result.floorTile = readImage(data / "arena_floor.png")
  except CatchableError:
    result.ok = false
    result.floorTile = newImage(32, 32)
    result.floorTile.fill(rgba(46, 42, 38, 255))
  try:
    result.wallH = readImage(art / "walls" / "wall_h.jpg")
  except CatchableError:
    result.ok = false
    result.wallH = newImage(CellPx, CellPx)
    result.wallH.fill(rgba(92, 78, 62, 255))
  try:
    result.wallV = readImage(art / "walls" / "wall_v.jpg")
  except CatchableError:
    result.ok = false
    result.wallV = result.wallH
  const crownFiles = ["soldier_red_crown.png", "soldier_blue_crown.png",
    "soldier_green_crown.png", "soldier_yellow_crown.png"]
  for seat in 0 ..< Seats:
    try:
      result.crowns[seat] = readImage(data / crownFiles[seat])
    except CatchableError:
      result.ok = false
      let fallback = newImage(CellPx, CellPx)
      fallback.fill(rgba(uint8(TeamColors[seat][0]), uint8(TeamColors[seat][1]),
        uint8(TeamColors[seat][2]), 255))
      result.crowns[seat] = fallback
  try:
    result.typeface = readTypeface(data / "atlas" / "nes-pixel.ttf")
  except CatchableError:
    try:
      result.typeface = readTypeface(data / "font.ttf")
    except CatchableError:
      result.ok = false
      result.typeface = nil

proc rgbaBytes*(image: Image): seq[uint8] =
  ## Straight (non-premultiplied) RGBA, which is what the sprite protocol
  ## and `putSpritePixel` expect.
  result = newSeq[uint8](image.width * image.height * 4)
  for i in 0 ..< image.width * image.height:
    let pixel = image.data[i]
    let alpha = int(pixel.a)
    if alpha == 0:
      continue
    result[i * 4] = uint8(min(255, int(pixel.r) * 255 div alpha))
    result[i * 4 + 1] = uint8(min(255, int(pixel.g) * 255 div alpha))
    result[i * 4 + 2] = uint8(min(255, int(pixel.b) * 255 div alpha))
    result[i * 4 + 3] = uint8(alpha)

proc bakeFloor*(art: ArtPack, w, h: int): Image =
  ## The board floor: `arena_floor.png` tiled and darkened 18 %, with a 1 px
  ## chalk grid on the cell lattice. Baked once at reset.
  result = newImage(w * CellPx, h * CellPx)
  let tile = art.floorTile
  var y = 0
  while y < result.height:
    var x = 0
    while x < result.width:
      result.draw(tile, translate(vec2(float32(x), float32(y))))
      x += tile.width
    y += tile.height
  ## Darken 18 %.
  for i in 0 ..< result.width * result.height:
    var pixel = result.data[i]
    pixel.r = uint8(int(pixel.r) * 82 div 100)
    pixel.g = uint8(int(pixel.g) * 82 div 100)
    pixel.b = uint8(int(pixel.b) * 82 div 100)
    result.data[i] = pixel
  ## The chalk grid.
  let chalk = rgba(214, 206, 190, 46)
  for gx in 0 .. w:
    let x = min(result.width - 1, gx * CellPx)
    for y2 in 0 ..< result.height:
      result[x, y2] = chalk
  for gy in 0 .. h:
    let y2 = min(result.height - 1, gy * CellPx)
    for x in 0 ..< result.width:
      result[x, y2] = chalk

proc cropTile*(source: Image, seedX, seedY, side: int): Image =
  ## A `side`-square crop of a wall texture, offset by the cell so no two
  ## mountains read as the same stamp, resized to one cell.
  let span = max(8, min(source.width, source.height) div 6)
  let maxX = max(0, source.width - span)
  let maxY = max(0, source.height - span)
  let ox = if maxX == 0: 0 else: abs(seedX * 137 + seedY * 71) mod maxX
  let oy = if maxY == 0: 0 else: abs(seedY * 199 + seedX * 43) mod maxY
  source.subImage(ox, oy, span, span).resize(side, side)

proc stampMountain*(floor: Image, art: ArtPack, x, y: int) =
  ## Mountains are rough blocks cut from the wall textures.
  let source = if (x + y) mod 2 == 0: art.wallH else: art.wallV
  let block16 = cropTile(source, x, y, CellPx)
  floor.draw(block16, translate(vec2(float32(x * CellPx), float32(y * CellPx))))
  ## A dark rim so a mountain reads as impassable at 12 px a cell.
  let rim = rgba(18, 15, 12, 210)
  for i in 0 ..< CellPx:
    floor[x * CellPx + i, y * CellPx] = rim
    floor[x * CellPx + i, y * CellPx + CellPx - 1] = rim
    floor[x * CellPx, y * CellPx + i] = rim
    floor[x * CellPx + CellPx - 1, y * CellPx + i] = rim

proc bakeTint*(seat, level: int): Image =
  ## The five-step ownership ramp: brighter with a bigger garrison.
  result = newImage(CellPx, CellPx)
  let color = TeamColors[seat]
  let scale = 55 + level * 12
  let alpha = uint8(120 + level * 22)
  result.fill(rgba(
    uint8(color[0] * scale div 100),
    uint8(color[1] * scale div 100),
    uint8(color[2] * scale div 100),
    alpha))
  ## A one-pixel inner border in the full team colour, so an owned tile has
  ## an edge even under the fog wash.
  let edge = rgba(uint8(color[0]), uint8(color[1]), uint8(color[2]), 235)
  for i in 0 ..< CellPx:
    result[i, 0] = edge
    result[i, CellPx - 1] = edge
    result[0, i] = edge
    result[CellPx - 1, i] = edge

proc bakeKeep*(art: ArtPack, seat: int): Image =
  ## A city keep: the wall texture, tinted to its owner (grey stone when
  ## neutral), with a crenellated top so it reads as a structure.
  result = newImage(CellPx, CellPx)
  let stone = cropTile(art.wallV, seat + 3, seat * 5 + 2, CellPx - 8)
  result.draw(stone, translate(vec2(4, 4)))
  var tintR = 150
  var tintG = 148
  var tintB = 142
  if seat >= 0:
    tintR = TeamColors[seat][0]
    tintG = TeamColors[seat][1]
    tintB = TeamColors[seat][2]
  for i in 0 ..< result.width * result.height:
    var pixel = result.data[i]
    if pixel.a == 0:
      continue
    pixel.r = uint8((int(pixel.r) + tintR) div 2)
    pixel.g = uint8((int(pixel.g) + tintG) div 2)
    pixel.b = uint8((int(pixel.b) + tintB) div 2)
    result.data[i] = pixel
  let merlon = rgba(uint8(tintR), uint8(tintG), uint8(tintB), 255)
  var x = 4
  while x < CellPx - 4:
    for dx in 0 ..< 3:
      if x + dx < CellPx - 4:
        result[x + dx, 3] = merlon
        result[x + dx, 4] = merlon
    x += 6

proc bakeCrown*(art: ArtPack, seat: int): Image =
  ## The general: the starter's crowned cog sprite, fitted to the cell.
  result = newImage(CellPx, CellPx)
  let source = art.crowns[seat]
  let side = CellPx - 4
  let fitted = source.resize(side, side)
  result.draw(fitted, translate(vec2(2, 2)))

proc bakeDigit*(art: ArtPack, digit: int): Image =
  ## One tabular numeral, set in nes-pixel so it stays pixel-exact at small
  ## sizes. A numeral is ALWAYS the exact integer: never "T", never "1.2k".
  let width = DigitH div 2 + 2
  result = newImage(width, DigitH)
  if art.typeface == nil:
    return
  let font = newFont(art.typeface)
  font.size = float32(DigitH - 2)
  font.paint = newPaint(SolidPaint)
  font.paint.color = color(1, 1, 1, 1)
  result.fillText(font, $digit, translate(vec2(1, 0)))
