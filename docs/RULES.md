# gen-generals-io — the rules

Four commanders. One 16 × 10 grid. Everyone starts on a crown in a corner,
sees only what they own and the ring around it, and spends one move a turn
pushing armies outward.

## The board

* `boardW` × `boardH` = **16 × 10** (12 × 8 in `blitz`), generated once at
  reset from the episode seed and **four-fold symmetric**: the top-left
  quadrant is drawn, then mirrored into the other three. Every seat gets a
  congruent start — the same crown offset, the same mountains, the same cities
  and the same distances to each rival.
* Cells are `plain`, `mountain`, `city` or `general`. Mountains are impassable
  and never owned. A cell holds an integer army.
* **8 mountains and 2 cities per quadrant** (32 and 8 on the board), placed by
  rejection sampling at Chebyshev ≥ 2 from the crown (mountains) and ≥ 3 from
  the crown and ≥ 2 from each other (cities). A symmetric connectivity repair
  then opens any pocket the mountains sealed off, converting the first
  mountain on the cheapest path **and its three mirror images** to plain — so
  the layout stays symmetric and every non-mountain cell stays reachable.
* Neutral cities hold **40** armies (50 in `citadels`) and are the only toll
  on the board.

## The turn

One tick is one turn. `maxTurns` = 240 (160 in `blitz`).

1. **Directive install** — every 8 turns each living seat's plan is installed.
2. **Move compilation** — the deterministic captain compiles one plan into at
   most one move per seat, from **that seat's fogged view only**.
3. **Move resolution**, one at a time, in the rotated order
   `order[k] = (turn + k) mod 4` — priority rounds the table every turn.
   * A move is discarded (and counted in `invalidMoves`) if the source is not
     owned, holds fewer than 2 armies, the target is off the board or a
     mountain, or the seat is no longer alive.
   * `amount` is clamped into `1 .. army(source) - 1`: a tile always keeps at
     least one army.
   * Onto your own tile the armies add. Onto a neutral or enemy tile: send
     **more** than the garrison and you take the tile with the difference on
     it; send the same or less and the tile keeps the difference and its owner.
4. **Per-turn growth** — every **owned** city and crown gains +1. Neutral
   cities do **not** grow.
5. **Periodic growth** — every `growthPeriod` (25) turns, every owned cell
   gains +1, whatever its kind.
6. **Vision and memory** — a seat sees a cell if it owns it or the cell
   touches one of its cells (all eight directions). What it saw is remembered
   with the turn it was seen; the army on a remembered cell is unknown.
7. **The sim guard** runs every turn.
8. **The hash** is written and the end conditions are checked.

## Crown capture

Move more armies onto a rival's crown than sit on it and you take
**everything they own**: every other tile they hold becomes yours with its
army halved (integer division), their crown becomes a **city** of yours
holding the surviving attacker army, and they are out of the game. The captor
gets a `generalcaptured` event and the victim an `eliminated` one.

## Scoring

Measured at the final turn, first difference decides:

1. still alive
2. among the dead, who lasted longer
3. most land
4. biggest army
5. most cities

`placePoint(rank) = (4 - 1 - rank) / (4 - 1)` → `[1, 2/3, 1/3, 0]`, averaged
over a tie group. **`sum(scores) == 2.0` on every episode**, ties included:
strictly constant-sum, higher is better, nothing is ever negative.

## Endings

| `reason` | `endRule` | when |
|---|---|---|
| `complete` | `conquest` | exactly one crown is left |
| `complete` | `full_time` | turn == `maxTurns` with two or more alive |
| `deadline` | `wall_clock` | the 660 s engine stop fired |
| `fault` | `sim_fault` | the sim guard tripped |
| `fault` | `host_error` | an unexpected server-side exception |

No other string is ever emitted.

## The scripted baselines

Both emit the same plan object an LLM does, through the same validator, and
both are pure functions of the seat's own fogged view.

**`sprawl`** — `defend` when the crown is threatened, `expand` while land is
under a quarter of the board, `attack` at the nearest visible enemy tile
otherwise. `reserve` 0, `cities` `cheap`, `scouts` 1. It is also the
per-turn fallback, the driver of a no-show seat, and the default.

**`crown`** — `defend` when threatened, `raid` the nearest known crown,
`expand` otherwise. `reserve` 20, `cities` `never`, `scouts` 2. Deliberately
a different SHAPE, so the ladder gets a spread rather than two versions of
one bot.

## Documented divergences from generals.io

This is an adaptation of a public specification, not a reproduction of
anyone's engine, and no test here compares a trajectory to a reference
implementation.

* A move carries an **explicit `amount`** in `1 .. army-1` rather than only
  "all" or "half". A strict superset, and it is what makes `reserve` exact.
* **Priority rotates by turn number** rather than by a server-side move queue.
* **Generals start at 1 army**, on a board generated by this repo's own
  symmetric generator.
* **Swamps, lookout towers, desert tiles and the 50/50 city-spawn variance
  are absent.**
* **A 240-turn clock** stands in for generals.io's open-ended games.
