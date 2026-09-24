## Export complete native games with each seat's hosted prompt and plan.

import std/[json, os, osproc, strutils]
import generals/[sim, decide, llm]

when isMainModule:
  let args = commandLineParams()
  if args.len != 3:
    quit("usage: gen-generals-posttrain OUTPUT EPISODES VARIANT", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  if episodes < 10: quit("at least ten games are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    var game = initSim(config)
    game.phase = phPlaying
    game.gameStartTick = config.startWaitTicks
    var rows: seq[string]
    var lastLand, lastArmy, lastCities: array[Seats, int]
    while not game.done:
      if game.isDirectiveTurn():
        let seats = game.aliveSeats()
        var decisions: seq[Decision]
        for seat in seats:
          let baseline = if (seat + seed) mod 2 == 0:
            skSprawl else: skCrown
          let teacher = scriptedDecision(game, seat, baseline)
          let completion = planJson(teacher.plan)
          var repaired = 0
          let (accepted, ok) = parsePlan($completion, game.plan[seat],
            game.havePlan[seat], repaired)
          doAssert ok and repaired == 0
          doAssert planJson(accepted) == completion
          let view = game.viewOf(seat)
          let observation = buildObservation(view, config,
            game.directiveIndex(), game.directiveCount(), game.plan[seat],
            game.havePlan[seat], game.howItWent(seat, lastLand[seat],
              lastArmy[seat], lastCities[seat]))
          decisions.add(Decision(plan: accepted, source: psScripted))
          rows.add($(%*{
            "episode_id": "gen-generals-io-" & variant & "-" & $seed,
            "seed": "gen-generals-io-" & variant & "-" & $seed,
            "decision_id": rows.len,
            "prompt": [
              {"role": "system", "content": systemPromptFor(config)},
              {"role": "user", "content": userMessage("", $observation)}
            ],
            "completion": [{"role": "assistant", "content": $completion}],
            "game": "gen-generals-io",
            "action_schema_revision": "gen-generals-plan-v1"
          }))
        for index, seat in seats:
          game.installPlan(seat, decisions[index].plan, psScripted, 0)
        for seat in 0 ..< Seats:
          lastLand[seat] = game.stats[seat].land
          lastArmy[seat] = int(game.stats[seat].army)
          lastCities[seat] = game.stats[seat].cities
      game.stepTurn()
    doAssert game.reason == "complete"
    if seed mod 5 == 0: validationRows.add(rows)
    else: trainRows.add(rows)
    let ranks = game.rankSeats(game.turnsPlayed())
    var ranking = newJArray()
    for seat in 0 ..< Seats: ranking.add(%ranks[seat].rank)
    runs.add(%*{"seed": seed, "turns": game.turn,
      "decisions": rows.len, "ranks": ranking, "reason": game.reason})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "gen-generals-io", "variant": variant,
    "source_revision": revision, "teacher": "sprawl-and-crown",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len, "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
