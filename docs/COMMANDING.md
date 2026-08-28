# Writing a generals plan prompt

A policy here is just a prompt. The game server holds your seat's
`PLAYER_PROMPT`, and every eight turns it sends Claude a fixed system prompt
(the rules), your guidance, and your seat's **fogged** view of the board. You
reply with one plan object; a deterministic captain executes it, one move a
turn, for the next eight turns.

## What you are actually deciding

```json
{"intent": "expand|gather|attack|defend|scout|raid",
 "target": [x, y] or null,
 "reserve": 0,
 "cities": "never|cheap|always",
 "scouts": 1,
 "note": "<=160 characters, spectator-only"}
```

* **`intent`** picks the mission the captain walks. `expand` claims the
  nearest unclaimed land, preferring land that already touches two of your
  tiles. `gather` walks your second-biggest stack into your biggest.
  `attack` walks your biggest stack at `target`, else the nearest visible
  enemy tile, else the nearest one you remember. `defend` walks armies home.
  `scout` sends at most 8 armies into the nearest fog. `raid` walks your
  biggest stack at the nearest crown you have SEEN, routing around visible
  enemy stacks bigger than itself.
* **`reserve`** is exact: when the captain moves off your crown it sends
  `army(crown) - 1 - reserve`, and it does not move at all if that is below 1.
* **`cities`** decides when a stack is spent on a neutral city: `always`
  buys when the stack beats the garrison, `cheap` when it doubles it.
* **`scouts`** is a share of TURNS, not a number of units: `scouts: 2` means
  two turns in every four go to walking into the dark.
* **`note`** never reaches another seat. It is the line a spectator reads in
  the match feed under your alias, and it is the whole reason a replay of
  this game is watchable.

## What the prompt should do

1. **Say what to do in the first thirty turns.** Land compounds; a plan that
   starts fighting on turn 8 loses to one that starts claiming.
2. **Read `standing`.** Land, army, cities and who is alive are PUBLIC every
   turn for every seat. It is the only rival information you can trust, and a
   rival whose land doubles in one plan has just eaten a crown.
3. **Say when to stop expanding.** The fog is the reason: you cannot raid a
   crown you have never seen, and `scouts` is what buys that knowledge.
4. **Name the defend trigger.** `your_general.threatened` is in the view.
   Losing your crown loses everything you built.
5. **Keep it under 4000 runes.** Anything longer is truncated, on a rune
   boundary.

## What the prompt cannot do

It cannot see a rival's plan, this turn's or any past turn's; it cannot read
another seat's `note`; it cannot learn which policy or player holds a rival
seat; and it cannot see the army, owner or kind of any cell outside
`visible ∪ remembered`. There is no channel to any other seat.

## Two worked examples

The shipped champions are in `tools/ci/policies.json`:
`gen-generals-io-landgrab` plays land as the only thing that compounds;
`gen-generals-io-regicide` buys map knowledge early and hunts crowns. They
are the same image and the same binary — only the environment differs.
