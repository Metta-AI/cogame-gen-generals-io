## The two scripted baselines. Both emit the SAME plan object an LLM does,
## through the same validator, and both are pure functions of the seat's own
## fogged view — which is what makes the bounded-orders test meaningful and
## what stops a filler from cheating the fog. Neither ever writes a note.
##
## `sprawl` is also the server-side per-turn fallback: the decision engine
## imports THIS proc rather than duplicating it, so the fallback and the
## filler cannot drift.

import sim_types, vision, captain

type
  Tuning* = object
    ## The swept knobs. `tools/tune_baselines.nim` runs the head-to-head and
    ## writes its pick to `tools/ci/baseline_tuning.json`; `ci.yml` re-runs
    ## the sweep with `--check` and `tests/test_gen_baselines.nim` asserts the
    ## shipped defaults ARE that pick.
    sprawlLandDivisor*: int
    crownReserve*: int
    crownScouts*: int

const DefaultTuning* = Tuning(
  sprawlLandDivisor: 4, crownReserve: 20, crownScouts: 2)

proc sprawlPlan*(view: SeatView, tuning = DefaultTuning): Plan =
  ## The strong simple generals.io opening, held all game: land is
  ## production, so take land until you hold a quarter of the board.
  result = Plan(intent: inExpand, hasTarget: false, reserve: 0,
    cities: cpCheap, scouts: 1, note: "")
  let boardCells = view.viewCells()
  if view.threatened():
    result.intent = inDefend
    return
  if view.land[view.seat] < boardCells div max(1, tuning.sprawlLandDivisor):
    result.intent = inExpand
    return
  result.intent = inAttack
  let stack = view.ownedCells()
  if stack.len > 0:
    ## The NEAREST visible enemy cell, measured from this seat's crown, not
    ## the lowest-index one. Ties break by cell index, so the choice is still
    ## a pure function of the view.
    var best = -1
    var bestDist = high(int)
    let home = view.generalCell
    for cell in 0 ..< view.viewCells():
      if view.isVisible(cell) and int(view.ownerNow[cell]) >= 0 and
          int(view.ownerNow[cell]) != view.seat:
        let dist =
          if home < 0: cell
          else: abs(view.viewX(cell) - view.viewX(home)) +
            abs(view.viewY(cell) - view.viewY(home))
        if best < 0 or dist < bestDist:
          best = cell
          bestDist = dist
    if best >= 0:
      result.hasTarget = true
      result.targetX = view.viewX(best)
      result.targetY = view.viewY(best)

proc crownPlan*(view: SeatView, tuning = DefaultTuning): Plan =
  ## Deliberately a different SHAPE, so the ladder gets a spread rather than
  ## two versions of one bot: it buys map knowledge early and pays in land.
  result = Plan(intent: inExpand, hasTarget: false, reserve: tuning.crownReserve,
    cities: cpNever, scouts: tuning.crownScouts, note: "")
  if view.threatened():
    result.intent = inDefend
    return
  let crowns = view.knownGenerals()
  if crowns.len > 0:
    var nearest = crowns[0]
    let home = view.generalCell
    if home >= 0:
      var bestDist = high(int)
      for crown in crowns:
        let distance = abs(view.viewX(crown) - view.viewX(home)) +
          abs(view.viewY(crown) - view.viewY(home))
        if distance < bestDist or (distance == bestDist and crown < nearest):
          bestDist = distance
          nearest = crown
    result.intent = inRaid
    result.hasTarget = true
    result.targetX = view.viewX(nearest)
    result.targetY = view.viewY(nearest)

proc scriptedPlan*(view: SeatView, kind: ScriptKind,
    tuning = DefaultTuning): Plan =
  case kind
  of skCrown: crownPlan(view, tuning)
  else: sprawlPlan(view, tuning)
