## The board: the seeded four-fold-symmetric generator, the cell arrays, the
## mirror orbit, the connectivity repair, and the BFS every consumer shares.
##
## Pure integer. No floating point routine appears in this file (CI greps it).

import std/[algorithm]
import sim_types, sim_config

type
  MapRng* = object
    ## One RNG stream, derived from `seed`, consumed ONLY by the generator at
    ## reset and never again, so nothing a policy does can steer a draw.
    state*: uint64
    stream*: uint64
    draws*: int

  Board* = object
    w*, h*: int
    kind*: seq[int8]          ## ord(CellKind)
    owner*: seq[int8]         ## -1 neutral, else the seat index
    army*: seq[int32]
    generalCell*: array[Seats, int]

const NoOwner* = -1'i8

proc initMapRng*(seed: int): MapRng =
  let raw = cast[uint64](seed)
  result.stream = (raw shl 1'u64) or 1'u64
  result.state = 0'u64
  result.state = result.state * 6364136223846793005'u64 + result.stream
  result.state = result.state + raw
  result.state = result.state * 6364136223846793005'u64 + result.stream

proc nextU32*(rng: var MapRng): uint32 =
  rng.draws.inc
  let old = rng.state
  rng.state = old * 6364136223846793005'u64 + rng.stream
  let xorshifted = uint32(((old shr 18'u64) xor old) shr 27'u64)
  let rot = uint32(old shr 59'u64)
  (xorshifted shr rot) or (xorshifted shl ((32'u32 - rot) and 31'u32))

proc rand*(rng: var MapRng, bound: int): int =
  ## Uniform in 0 ..< bound (bound >= 1).
  if bound <= 1:
    return 0
  int(rng.nextU32() mod uint32(bound))

# ---- cell helpers -------------------------------------------------------

proc cellIndex*(board: Board, x, y: int): int {.inline.} =
  y * board.w + x

proc cellX*(board: Board, cell: int): int {.inline.} =
  cell mod board.w

proc cellY*(board: Board, cell: int): int {.inline.} =
  cell div board.w

proc cellCount*(board: Board): int {.inline.} =
  board.w * board.h

proc onBoard*(board: Board, x, y: int): bool {.inline.} =
  x >= 0 and y >= 0 and x < board.w and y < board.h

proc kindOf*(board: Board, cell: int): CellKind {.inline.} =
  CellKind(board.kind[cell])

proc ownerOf*(board: Board, cell: int): int {.inline.} =
  int(board.owner[cell])

proc armyOf*(board: Board, cell: int): int {.inline.} =
  int(board.army[cell])

proc chebyshev*(board: Board, a, b: int): int =
  let dx = abs(board.cellX(a) - board.cellX(b))
  let dy = abs(board.cellY(a) - board.cellY(b))
  max(dx, dy)

proc neighbours4*(board: Board, cell: int): seq[int] =
  ## N, E, S, W in that fixed order, so every path in this repo is unique.
  let x = board.cellX(cell)
  let y = board.cellY(cell)
  for dir in Dir:
    let (dx, dy) = dirDelta(dir)
    if board.onBoard(x + dx, y + dy):
      result.add(board.cellIndex(x + dx, y + dy))

proc neighbours8*(board: Board, cell: int): seq[int] =
  let x = board.cellX(cell)
  let y = board.cellY(cell)
  for dy in -1 .. 1:
    for dx in -1 .. 1:
      if dx == 0 and dy == 0:
        continue
      if board.onBoard(x + dx, y + dy):
        result.add(board.cellIndex(x + dx, y + dy))

proc mirrorCells*(board: Board, cell: int): array[4, int] =
  ## The mirror orbit of a top-left-quadrant cell: (x,y), (W-1-x,y),
  ## (x,H-1-y), (W-1-x,H-1-y) — quadrant order top-left, top-right,
  ## bottom-left, bottom-right, which is also seat order.
  let x = board.cellX(cell)
  let y = board.cellY(cell)
  [board.cellIndex(x, y),
   board.cellIndex(board.w - 1 - x, y),
   board.cellIndex(x, board.h - 1 - y),
   board.cellIndex(board.w - 1 - x, board.h - 1 - y)]

# ---- generation ---------------------------------------------------------

proc blankBoard*(w, h: int): Board =
  result.w = w
  result.h = h
  result.kind = newSeq[int8](w * h)
  result.owner = newSeq[int8](w * h)
  result.army = newSeq[int32](w * h)
  for i in 0 ..< w * h:
    result.kind[i] = int8(ord(ckPlain))
    result.owner[i] = NoOwner
    result.army[i] = 0
  for seat in 0 ..< Seats:
    result.generalCell[seat] = -1

proc floodReachable(board: Board, start: int): seq[bool] =
  result = newSeq[bool](board.cellCount())
  if start < 0:
    return
  var queue = @[start]
  result[start] = true
  var head = 0
  while head < queue.len:
    let cell = queue[head]
    head.inc
    for next in board.neighbours4(cell):
      if result[next] or board.kindOf(next) == ckMountain:
        continue
      result[next] = true
      queue.add(next)

proc firstMountainOnPath(board: Board, reached: seq[bool], goal: int): int =
  ## Dijkstra from the reached set to `goal` with a mountain costing 1000 and
  ## everything else 1; returns the first mountain cell on the cheapest path
  ## (ties by lowest cell index), or -1.
  let n = board.cellCount()
  var dist = newSeq[int](n)
  var firstRock = newSeq[int](n)
  var done = newSeq[bool](n)
  for i in 0 ..< n:
    dist[i] = high(int) div 4
    firstRock[i] = -1
  for i in 0 ..< n:
    if reached[i]:
      dist[i] = 0
  while true:
    var best = -1
    for i in 0 ..< n:
      if not done[i] and dist[i] < (high(int) div 4) and
          (best < 0 or dist[i] < dist[best]):
        best = i
    if best < 0:
      return -1
    if best == goal:
      return firstRock[best]
    done[best] = true
    for next in board.neighbours4(best):
      if done[next]:
        continue
      let step = if board.kindOf(next) == ckMountain: 1000 else: 1
      let candidate = dist[best] + step
      if candidate < dist[next]:
        dist[next] = candidate
        firstRock[next] =
          if firstRock[best] >= 0: firstRock[best]
          elif board.kindOf(next) == ckMountain: next
          else: -1

proc generateBoard*(config: GameConfig): Board =
  ## A pure function of (seed, boardW, boardH, mountainPct, cityCount,
  ## cityArmy). `mapRng` is consumed here and nowhere else in the episode.
  result = blankBoard(config.boardW, config.boardH)
  var rng = initMapRng(config.seed)
  let qw = config.boardW div 2
  let qh = config.boardH div 2

  # 2. the general, never on a board edge.
  let gx = 1 + rng.rand(max(1, qw - 2))
  let gy = 1 + rng.rand(max(1, qh - 2))
  let generalQ = result.cellIndex(gx, gy)

  # 3. mountains, rejection-sampled at Chebyshev >= 2 from the general.
  let mountains = (qw * qh * config.mountainPct) div 100
  var placedMountains = 0
  var attempts = 0
  var mountainGap = 2
  while placedMountains < mountains:
    attempts.inc
    if attempts > 500 and (attempts - 500) mod 200 == 0 and mountainGap > 0:
      mountainGap.dec
    if attempts > 20000:
      break
    let cell = result.cellIndex(rng.rand(qw), rng.rand(qh))
    if cell == generalQ or result.kindOf(cell) != ckPlain:
      continue
    if result.chebyshev(cell, generalQ) < mountainGap:
      continue
    result.kind[cell] = int8(ord(ckMountain))
    placedMountains.inc

  # 4. cities, at Chebyshev >= 3 from the general and >= 2 from each other.
  let cities = config.cityCount div 4
  var placedCities: seq[int] = @[]
  attempts = 0
  var cityGeneralGap = 3
  var cityGap = 2
  while placedCities.len < cities:
    attempts.inc
    if attempts > 500 and (attempts - 500) mod 200 == 0:
      if cityGeneralGap > 1: cityGeneralGap.dec
      if cityGap > 1: cityGap.dec
    if attempts > 20000:
      break
    let cell = result.cellIndex(rng.rand(qw), rng.rand(qh))
    if cell == generalQ or result.kindOf(cell) != ckPlain:
      continue
    if result.chebyshev(cell, generalQ) < cityGeneralGap:
      continue
    var tooClose = false
    for other in placedCities:
      if result.chebyshev(cell, other) < cityGap:
        tooClose = true
        break
    if tooClose:
      continue
    result.kind[cell] = int8(ord(ckCity))
    result.army[cell] = int32(config.cityArmy)
    placedCities.add(cell)

  # 5. mirror the quadrant into the other three.
  for qy in 0 ..< qh:
    for qx in 0 ..< qw:
      let source = result.cellIndex(qx, qy)
      let orbit = result.mirrorCells(source)
      for q in 1 .. 3:
        result.kind[orbit[q]] = result.kind[source]
        result.army[orbit[q]] = result.army[source]
        result.owner[orbit[q]] = NoOwner
  for seat in 0 ..< Seats:
    let orbit = result.mirrorCells(generalQ)
    result.generalCell[seat] = orbit[seat]
    result.kind[orbit[seat]] = int8(ord(ckGeneral))
    result.owner[orbit[seat]] = int8(seat)
    result.army[orbit[seat]] = 1

  # 6. symmetric connectivity repair.
  var guard = 0
  while true:
    guard.inc
    if guard > result.cellCount():
      break
    let reached = floodReachable(result, result.generalCell[0])
    var unreached = -1
    for cell in 0 ..< result.cellCount():
      if result.kindOf(cell) != ckMountain and not reached[cell]:
        unreached = cell
        break
    if unreached < 0:
      break
    let rock = firstMountainOnPath(result, reached, unreached)
    if rock < 0:
      break
    for mirror in result.mirrorCells(rock):
      if result.kindOf(mirror) == ckMountain:
        result.kind[mirror] = int8(ord(ckPlain))
        result.army[mirror] = 0
        result.owner[mirror] = NoOwner

proc mountainSymmetric*(board: Board): bool =
  ## The mountain layout stays four-fold symmetric for the whole episode:
  ## ownership and armies diverge the moment anyone moves, kinds never do.
  for y in 0 ..< board.h div 2:
    for x in 0 ..< board.w div 2:
      let orbit = board.mirrorCells(board.cellIndex(x, y))
      let isRock = board.kindOf(orbit[0]) == ckMountain
      for q in 1 .. 3:
        if (board.kindOf(orbit[q]) == ckMountain) != isRock:
          return false
  true

proc allReachable*(board: Board): bool =
  var start = -1
  for cell in 0 ..< board.cellCount():
    if board.kindOf(cell) != ckMountain:
      start = cell
      break
  if start < 0:
    return true
  let reached = floodReachable(board, start)
  for cell in 0 ..< board.cellCount():
    if board.kindOf(cell) != ckMountain and not reached[cell]:
      return false
  true

proc countKind*(board: Board, kind: CellKind): int =
  for cell in 0 ..< board.cellCount():
    if board.kindOf(cell) == kind:
      result.inc

proc sortedCells*(cells: seq[int]): seq[int] =
  result = cells
  result.sort()
