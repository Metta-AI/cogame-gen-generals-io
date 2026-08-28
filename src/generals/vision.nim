## Fog of war: the per-seat visible set, the memory arrays, and `view(s)` —
## the ONE structure both the observation builder and the captain read, so a
## seat's model and its captain can never disagree about what is known.
##
## Pure integer.

import sim_types, board

type
  SeatView* = object
    ## Everything seat `s` knows. The true board is never handed to the
    ## captain: `tests/test_gen_captain.nim` runs it against a view built
    ## from a garbage board and requires the identical move.
    seat*: int
    w*, h*: int
    turn*: int
    maxTurns*: int
    growthPeriod*: int
    visible*: seq[bool]
    seenTurn*: seq[int]        ## -1 = never seen
    kindSeen*: seq[int8]
    ownerSeen*: seq[int8]
    kindNow*: seq[int8]        ## only meaningful where `visible`
    ownerNow*: seq[int8]
    armyNow*: seq[int32]
    generalCell*: int
    alive*: array[Seats, bool]
    land*: array[Seats, int]
    armyTotal*: array[Seats, int]
    cities*: array[Seats, int]
    outTurn*: array[Seats, int]
    outTo*: array[Seats, int]

  Memory* = object
    seenTurn*: seq[int]
    kindSeen*: seq[int8]
    ownerSeen*: seq[int8]

proc initMemory*(cells: int): Memory =
  result.seenTurn = newSeq[int](cells)
  result.kindSeen = newSeq[int8](cells)
  result.ownerSeen = newSeq[int8](cells)
  for i in 0 ..< cells:
    result.seenTurn[i] = -1
    result.kindSeen[i] = int8(ord(ckPlain))
    result.ownerSeen[i] = NoOwner

proc visibleSet*(board: Board, seat: int): seq[bool] =
  ## Owned cells plus every cell at Chebyshev distance 1 from an owned cell.
  result = newSeq[bool](board.cellCount())
  for cell in 0 ..< board.cellCount():
    if board.ownerOf(cell) == seat:
      result[cell] = true
      for near in board.neighbours8(cell):
        result[near] = true

proc rememberVisible*(memory: var Memory, board: Board,
    visible: seq[bool], turn: int) =
  for cell in 0 ..< board.cellCount():
    if visible[cell]:
      memory.seenTurn[cell] = turn
      memory.kindSeen[cell] = board.kind[cell]
      memory.ownerSeen[cell] = board.owner[cell]

proc memoryDigest*(memory: Memory): (int, int) =
  ## (count of seen cells, xor of (cellIndex * 31 + kindSeen)). The fog is
  ## game state, so a divergence in it must be caught by the hash chain.
  var count = 0
  var mixed = 0
  for cell in 0 ..< memory.seenTurn.len:
    if memory.seenTurn[cell] >= 0:
      count.inc
      mixed = mixed xor (cell * 31 + int(memory.kindSeen[cell]))
  (count, mixed)

proc buildView*(board: Board, memory: Memory, visible: seq[bool],
    seat, turn, maxTurns, growthPeriod: int,
    alive: array[Seats, bool], land, armyTotal, cities,
    outTurn, outTo: array[Seats, int]): SeatView =
  result.seat = seat
  result.w = board.w
  result.h = board.h
  result.turn = turn
  result.maxTurns = maxTurns
  result.growthPeriod = growthPeriod
  result.visible = visible
  result.seenTurn = memory.seenTurn
  result.kindSeen = memory.kindSeen
  result.ownerSeen = memory.ownerSeen
  result.generalCell = board.generalCell[seat]
  result.alive = alive
  result.land = land
  result.armyTotal = armyTotal
  result.cities = cities
  result.outTurn = outTurn
  result.outTo = outTo
  let cells = board.cellCount()
  result.kindNow = newSeq[int8](cells)
  result.ownerNow = newSeq[int8](cells)
  result.armyNow = newSeq[int32](cells)
  for cell in 0 ..< cells:
    if visible[cell]:
      result.kindNow[cell] = board.kind[cell]
      result.ownerNow[cell] = board.owner[cell]
      result.armyNow[cell] = board.army[cell]
    else:
      ## Outside the fog the view carries NOTHING from the true board: a
      ## remembered cell reports its last-seen kind and owner, and its army
      ## is unknown.
      result.kindNow[cell] = int8(ord(ckPlain))
      result.ownerNow[cell] = NoOwner
      result.armyNow[cell] = 0

# ---- queries the captain and the observation share ---------------------

proc cellIndexOf*(view: SeatView, x, y: int): int {.inline.} =
  y * view.w + x

proc viewX*(view: SeatView, cell: int): int {.inline.} = cell mod view.w
proc viewY*(view: SeatView, cell: int): int {.inline.} = cell div view.w
proc viewCells*(view: SeatView): int {.inline.} = view.w * view.h

proc onView*(view: SeatView, x, y: int): bool {.inline.} =
  x >= 0 and y >= 0 and x < view.w and y < view.h

proc isVisible*(view: SeatView, cell: int): bool {.inline.} =
  view.visible[cell]

proc isRemembered*(view: SeatView, cell: int): bool {.inline.} =
  view.seenTurn[cell] >= 0 and not view.visible[cell]

proc isUnknown*(view: SeatView, cell: int): bool {.inline.} =
  view.seenTurn[cell] < 0

proc knownKind*(view: SeatView, cell: int): CellKind {.inline.} =
  ## The kind as of the last look — the current kind for a visible cell.
  if view.visible[cell]: CellKind(view.kindNow[cell])
  else: CellKind(view.kindSeen[cell])

proc knownOwner*(view: SeatView, cell: int): int {.inline.} =
  if view.visible[cell]: int(view.ownerNow[cell])
  else: int(view.ownerSeen[cell])

proc knownArmy*(view: SeatView, cell: int): int {.inline.} =
  ## Only a VISIBLE cell reports an army. A remembered cell's garrison is
  ## unknown, and this proc says 0 rather than a stale number; every caller
  ## that cares tests `isVisible` first.
  if view.visible[cell]: int(view.armyNow[cell]) else: 0

proc ownsCell*(view: SeatView, cell: int): bool {.inline.} =
  view.visible[cell] and int(view.ownerNow[cell]) == view.seat

proc knownMountain*(view: SeatView, cell: int): bool {.inline.} =
  view.seenTurn[cell] >= 0 and view.knownKind(cell) == ckMountain

proc viewNeighbours4*(view: SeatView, cell: int): seq[int] =
  let x = view.viewX(cell)
  let y = view.viewY(cell)
  for dir in Dir:
    let (dx, dy) = dirDelta(dir)
    if view.onView(x + dx, y + dy):
      result.add(view.cellIndexOf(x + dx, y + dy))

proc viewNeighbours8*(view: SeatView, cell: int): seq[int] =
  let x = view.viewX(cell)
  let y = view.viewY(cell)
  for dy in -1 .. 1:
    for dx in -1 .. 1:
      if dx == 0 and dy == 0:
        continue
      if view.onView(x + dx, y + dy):
        result.add(view.cellIndexOf(x + dx, y + dy))

proc ownedCells*(view: SeatView): seq[int] =
  for cell in 0 ..< view.viewCells():
    if view.ownsCell(cell):
      result.add(cell)

proc dirBetween*(view: SeatView, fromCell, toCell: int): (Dir, bool) =
  let dx = view.viewX(toCell) - view.viewX(fromCell)
  let dy = view.viewY(toCell) - view.viewY(fromCell)
  if dx == 0 and dy == -1: return (dirN, true)
  if dx == 1 and dy == 0: return (dirE, true)
  if dx == 0 and dy == 1: return (dirS, true)
  if dx == -1 and dy == 0: return (dirW, true)
  (dirN, false)
