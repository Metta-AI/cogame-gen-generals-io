## The captain: the deterministic compiler that turns one plan into exactly
## one legal move per turn, from the seat's OWN fogged view.
##
## Forked from coworld-ctf's `src/ctf/control.nim` (directive -> per-tick
## actuation), retargeted from pixel steering to a single discrete move.
## There is no randomness in it at all and it reads only `SeatView`, which is
## what makes this a fog game rather than a fog costume. Pure integer.

import std/[algorithm]
import sim_types, sim_config, vision, sim_state

const
  UnknownStepCost = 2
  KnownStepCost = 1
  RaidDangerCost = 8
  MissionMaxStepsDefault = 12

type
  PathResult* = object
    dist*: seq[int]
    prev*: seq[int]

  Heap = object
    items: seq[(int, int)]     ## (distance, cell)

proc push(heap: var Heap, item: (int, int)) =
  heap.items.add(item)
  var i = heap.items.len - 1
  while i > 0:
    let parent = (i - 1) div 2
    if heap.items[parent] <= heap.items[i]:
      break
    swap(heap.items[parent], heap.items[i])
    i = parent

proc pop(heap: var Heap): (int, int) =
  result = heap.items[0]
  let last = heap.items.pop()
  if heap.items.len > 0:
    heap.items[0] = last
    var i = 0
    while true:
      let left = i * 2 + 1
      let right = left + 1
      var best = i
      if left < heap.items.len and heap.items[left] < heap.items[best]:
        best = left
      if right < heap.items.len and heap.items[right] < heap.items[best]:
        best = right
      if best == i:
        break
      swap(heap.items[best], heap.items[i])
      i = best

proc dangerous(view: SeatView, cell, amount: int): bool =
  ## In `raid` mode a cell orthogonally adjacent to a currently-visible enemy
  ## stack at least as big as the moving amount costs +8.
  for near in view.viewNeighbours4(cell):
    if view.isVisible(near) and int(view.ownerNow[near]) >= 0 and
        int(view.ownerNow[near]) != view.seat and
        view.knownArmy(near) >= amount:
      return true
  false

proc shortestPaths*(view: SeatView, source: int, raidMode: bool,
    amount: int): PathResult =
  ## Breadth-first over the view: known mountains impassable, unknown cells
  ## cost 2, everything else 1. Neighbours expand in the fixed order N, E, S,
  ## W, so the path is unique; ties break by lowest cell index.
  let cells = view.viewCells()
  result.dist = newSeq[int](cells)
  result.prev = newSeq[int](cells)
  for i in 0 ..< cells:
    result.dist[i] = high(int) div 4
    result.prev[i] = -1
  if source < 0 or source >= cells:
    return
  result.dist[source] = 0
  var heap = Heap()
  heap.push((0, source))
  while heap.items.len > 0:
    let (distance, cell) = heap.pop()
    if distance > result.dist[cell]:
      continue
    for next in view.viewNeighbours4(cell):
      if view.knownMountain(next):
        continue
      var step = if view.isUnknown(next): UnknownStepCost else: KnownStepCost
      if raidMode and view.isVisible(next) and view.dangerous(next, amount):
        step += RaidDangerCost
      let candidate = distance + step
      if candidate < result.dist[next] or
          (candidate == result.dist[next] and cell < result.prev[next]):
        result.dist[next] = candidate
        result.prev[next] = cell
        heap.push((candidate, next))

proc firstStep*(path: PathResult, source, goal: int): int =
  ## The first cell on the path from `source` to `goal`, or -1.
  if goal < 0 or goal == source:
    return -1
  if path.dist[goal] >= high(int) div 4:
    return -1
  var cursor = goal
  while path.prev[cursor] >= 0 and path.prev[cursor] != source:
    cursor = path.prev[cursor]
  if path.prev[cursor] == source: cursor else: -1

proc bestGoal(path: PathResult, candidates: seq[int]): int =
  var best = -1
  for candidate in candidates:
    if path.dist[candidate] >= high(int) div 4:
      continue
    if best < 0 or path.dist[candidate] < path.dist[best] or
        (path.dist[candidate] == path.dist[best] and candidate < best):
      best = candidate
  best

proc largestOwned*(view: SeatView, exclude = -1, minArmy = 2): int =
  ## The owned cell with the largest army; ties by lowest cell index.
  var best = -1
  for cell in view.ownedCells():
    if cell == exclude or view.knownArmy(cell) < minArmy:
      continue
    if best < 0 or view.knownArmy(cell) > view.knownArmy(best):
      best = cell
  best

proc secondLargestOwned*(view: SeatView): int =
  let first = view.largestOwned()
  if first < 0:
    return -1
  view.largestOwned(exclude = first)

proc unknownCells(view: SeatView): seq[int] =
  for cell in 0 ..< view.viewCells():
    if view.isUnknown(cell):
      result.add(cell)

proc claimableCells(view: SeatView): seq[int] =
  ## Unclaimed land: an unknown cell, or a known empty plain that is not ours.
  for cell in 0 ..< view.viewCells():
    if view.ownsCell(cell):
      continue
    if view.isUnknown(cell):
      result.add(cell)
    elif view.knownKind(cell) == ckPlain and view.knownOwner(cell) < 0 and
        (not view.isVisible(cell) or view.knownArmy(cell) == 0):
      result.add(cell)

proc enemyCells(view: SeatView, visibleOnly: bool): seq[int] =
  for cell in 0 ..< view.viewCells():
    if visibleOnly:
      if view.isVisible(cell) and int(view.ownerNow[cell]) >= 0 and
          int(view.ownerNow[cell]) != view.seat:
        result.add(cell)
    else:
      if view.isRemembered(cell) and view.knownOwner(cell) >= 0 and
          view.knownOwner(cell) != view.seat:
        result.add(cell)

proc knownGenerals*(view: SeatView): seq[int] =
  for cell in 0 ..< view.viewCells():
    if view.seenTurn[cell] < 0:
      continue
    if view.knownKind(cell) == ckGeneral and
        view.knownOwner(cell) != view.seat:
      result.add(cell)

proc knownNeutralCities*(view: SeatView): seq[int] =
  for cell in 0 ..< view.viewCells():
    if view.seenTurn[cell] < 0:
      continue
    if view.knownKind(cell) == ckCity and view.knownOwner(cell) < 0:
      result.add(cell)

proc rememberedCityArmy(view: SeatView, cell: int, cityArmy: int): int =
  if view.isVisible(cell): view.knownArmy(cell) else: cityArmy

proc threatened*(view: SeatView): bool =
  ## A currently-visible cell within Chebyshev 2 of the crown, owned by
  ## another seat, with at least the crown's garrison.
  let crown = view.generalCell
  if crown < 0:
    return false
  let garrison = view.knownArmy(crown)
  let cx = view.viewX(crown)
  let cy = view.viewY(crown)
  for dy in -2 .. 2:
    for dx in -2 .. 2:
      if dx == 0 and dy == 0:
        continue
      if not view.onView(cx + dx, cy + dy):
        continue
      let cell = view.cellIndexOf(cx + dx, cy + dy)
      if view.isVisible(cell) and int(view.ownerNow[cell]) >= 0 and
          int(view.ownerNow[cell]) != view.seat and
          view.knownArmy(cell) >= garrison:
        return true
  false

proc amountFor(view: SeatView, source: int, plan: Plan, scoutArmy: int,
    scouting: bool): int =
  var amount = view.knownArmy(source) - 1
  if scouting:
    amount = min(scoutArmy, amount)
  if source == view.generalCell:
    amount = view.knownArmy(source) - 1 - plan.reserve
  amount

proc emitStep(view: SeatView, source, step, amount: int): (Move, bool) =
  if source < 0 or step < 0 or amount < 1:
    return (Move(), false)
  if not view.ownsCell(source) or view.knownArmy(source) < 2:
    return (Move(), false)
  if view.knownMountain(step):
    return (Move(), false)
  let (dir, ok) = view.dirBetween(source, step)
  if not ok:
    return (Move(), false)
  (Move(fromCell: source, dir: dir, amount: min(amount,
    view.knownArmy(source) - 1)), true)

proc compileMove*(view: SeatView, plan: Plan, seat: int,
    mission: var MissionState, config: GameConfig): (Move, bool) =
  ## Once per living seat per turn, in the design note's numbered order.
  ## Returns (move, emitted); `emitted == false` means the seat passes.
  if view.generalCell < 0:
    mission.active = false
    return (Move(), false)

  # 1. no material
  let anyMaterial = view.largestOwned() >= 0
  if not anyMaterial:
    mission.active = false
    return (Move(), false)

  let maxSteps =
    if config.missionMaxSteps > 0: config.missionMaxSteps
    else: MissionMaxStepsDefault

  # 2. threat override — re-arms every turn the threat is visible and cannot
  # be switched off by a plan (the system prompt announces it).
  if view.threatened():
    mission = MissionState(kind: mkDefend, source: -1,
      goal: view.generalCell, stepsLeft: config.defendTurns, active: true)

  # 3. continue an existing mission
  if mission.active and mission.stepsLeft > 0 and mission.source >= 0 and
      mission.goal >= 0 and mission.goal != mission.source:
    let path = view.shortestPaths(mission.source,
      mission.kind == mkRaid, view.knownArmy(mission.source) - 1)
    let step = path.firstStep(mission.source, mission.goal)
    let amount = view.amountFor(mission.source, plan, config.scoutArmy,
      mission.kind == mkScout)
    let (move, ok) = view.emitStep(mission.source, step, amount)
    if ok:
      mission.stepsLeft.dec
      mission.source = step
      if mission.source == mission.goal:
        mission.active = false
      return (move, true)
    mission.active = false

  # 4. scout slot
  var kind = mkNone
  var source = -1
  var goal = -1
  var scouting = false
  let fog = view.unknownCells()
  if (view.turn mod 4) < plan.scouts and fog.len > 0:
    var bestSource = -1
    var bestDist = high(int)
    var bestGoalCell = -1
    for cell in view.ownedCells():
      if view.knownArmy(cell) < 2:
        continue
      let path = view.shortestPaths(cell, false, view.knownArmy(cell) - 1)
      let target = path.bestGoal(fog)
      if target < 0:
        continue
      let distance = path.dist[target]
      if bestSource < 0 or distance < bestDist or
          (distance == bestDist and
            view.knownArmy(cell) > view.knownArmy(bestSource)) or
          (distance == bestDist and
            view.knownArmy(cell) == view.knownArmy(bestSource) and
            cell < bestSource):
        bestSource = cell
        bestDist = distance
        bestGoalCell = target
    if bestSource >= 0:
      kind = mkScout
      source = bestSource
      goal = bestGoalCell
      scouting = true

  # 5. city override
  if kind == mkNone and plan.cities != cpNever:
    let stack = view.largestOwned()
    if stack >= 0:
      let path = view.shortestPaths(stack, false, view.knownArmy(stack) - 1)
      var best = -1
      for city in view.knownNeutralCities():
        if path.dist[city] > 6:
          continue
        if best < 0 or path.dist[city] < path.dist[best] or
            (path.dist[city] == path.dist[best] and city < best):
          best = city
      if best >= 0:
        let garrison = view.rememberedCityArmy(best, config.cityArmy)
        let reserve = if stack == view.generalCell: plan.reserve else: 0
        let spendable = view.knownArmy(stack) - 1 - reserve
        let affordable =
          if plan.cities == cpAlways: spendable > garrison
          else: spendable > 2 * garrison
        if affordable:
          kind = mkCity
          source = stack
          goal = best

  # 6. intent mission
  if kind == mkNone:
    var intent = plan.intent
    var guard = 0
    while guard < 4:
      guard.inc
      case intent
      of inExpand:
        let stack = view.largestOwned()
        if stack < 0:
          break
        let path = view.shortestPaths(stack, false, view.knownArmy(stack) - 1)
        let candidates = view.claimableCells()
        var best = -1
        var bestTouch = -1
        for candidate in candidates:
          if path.dist[candidate] >= high(int) div 4:
            continue
          var touch = 0
          for near in view.viewNeighbours4(candidate):
            if view.ownsCell(near):
              touch.inc
          let prefer = if touch >= 2: 1 else: 0
          if best < 0 or path.dist[candidate] < path.dist[best] or
              (path.dist[candidate] == path.dist[best] and prefer > bestTouch) or
              (path.dist[candidate] == path.dist[best] and
                prefer == bestTouch and candidate < best):
            best = candidate
            bestTouch = prefer
        if best >= 0:
          kind = mkExpand
          source = stack
          goal = best
        break
      of inGather:
        let hammer = view.largestOwned()
        let feeder = view.secondLargestOwned()
        if hammer < 0 or feeder < 0:
          intent = inExpand
          continue
        kind = mkGather
        source = feeder
        goal = hammer
        break
      of inAttack:
        let stack = view.largestOwned()
        if stack < 0:
          break
        let path = view.shortestPaths(stack, false, view.knownArmy(stack) - 1)
        var target = -1
        if plan.hasTarget:
          let cell = view.cellIndexOf(
            clamp(plan.targetX, 0, view.w - 1),
            clamp(plan.targetY, 0, view.h - 1))
          if not view.knownMountain(cell):
            target = cell
        if target < 0:
          target = path.bestGoal(view.enemyCells(true))
        if target < 0:
          target = path.bestGoal(view.enemyCells(false))
        if target < 0:
          intent = inExpand
          continue
        kind = mkAttack
        source = stack
        goal = target
        break
      of inDefend:
        let crown = view.generalCell
        let stack = view.largestOwned(exclude = crown)
        var needed = view.threatened()
        if not needed:
          for near in view.viewNeighbours4(crown):
            if not view.ownsCell(near) and not view.knownMountain(near):
              needed = true
              break
        if stack < 0 or not needed:
          intent = inExpand
          continue
        kind = mkDefend
        source = stack
        goal = crown
        break
      of inScout:
        if fog.len == 0:
          intent = inExpand
          continue
        var bestSource = -1
        var bestDist = high(int)
        var bestGoalCell = -1
        for cell in view.ownedCells():
          if view.knownArmy(cell) < 2:
            continue
          let path = view.shortestPaths(cell, false, view.knownArmy(cell) - 1)
          let target = path.bestGoal(fog)
          if target < 0:
            continue
          if bestSource < 0 or path.dist[target] < bestDist:
            bestSource = cell
            bestDist = path.dist[target]
            bestGoalCell = target
        if bestSource < 0:
          intent = inExpand
          continue
        kind = mkScout
        source = bestSource
        goal = bestGoalCell
        scouting = true
        break
      of inRaid:
        let crowns = view.knownGenerals()
        if crowns.len == 0:
          intent = inScout
          continue
        let stack = view.largestOwned()
        if stack < 0:
          break
        let path = view.shortestPaths(stack, true, view.knownArmy(stack) - 1)
        let target = path.bestGoal(crowns)
        if target < 0:
          intent = inExpand
          continue
        kind = mkRaid
        source = stack
        goal = target
        break

  # 7. amount, and 8. nothing legal
  if kind == mkNone or source < 0 or goal < 0 or source == goal:
    mission.active = false
    return (Move(), false)
  let path = view.shortestPaths(source, kind == mkRaid,
    view.knownArmy(source) - 1)
  let step = path.firstStep(source, goal)
  let amount = view.amountFor(source, plan, config.scoutArmy, scouting)
  if source == view.generalCell and amount < 1:
    mission.active = false
    return (Move(), false)
  let (move, ok) = view.emitStep(source, step, amount)
  if not ok:
    mission.active = false
    return (Move(), false)
  mission = MissionState(kind: kind, source: step, goal: goal,
    stepsLeft: maxSteps - 1, active: step != goal)
  (move, true)

proc sortedCopy*(cells: seq[int]): seq[int] =
  result = cells
  result.sort()
