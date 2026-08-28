## Test 21 — the manifest, checked against the engine it describes.

import std/[unittest, json, os, sequtils, strutils]
import generals/sim as gensim
import generals/roster

proc manifest(): JsonNode =
  var path = "coworld_manifest_template.json"
  if not fileExists(path):
    path = "../coworld_manifest_template.json"
  check fileExists(path)
  parseJson(readFile(path))

proc repoFile(name: string): string =
  if fileExists(name): readFile(name) else: readFile("../" & name)

suite "the manifest":
  test "num_agents is 4 in every variant and in the cert fixture":
    let m = manifest()
    check m["variants"].len == 3
    for variant in m["variants"]:
      check variant["game_config"]["num_agents"].getInt() == 4
      ## NEVER at a variant's top level: CoworldVariant is
      ## additionalProperties:false and rejects it.
      check not variant.hasKey("num_agents")
      check variant.hasKey("id")
      check variant.hasKey("name")
      check variant["description"].getStr().len > 0
    check m["certification"]["game_config"]["num_agents"].getInt() == 4

  test "no game_config anywhere carries a literal tokens array":
    let m = manifest()
    for variant in m["variants"]:
      check not variant["game_config"].hasKey("tokens")
    check not m["certification"]["game_config"].hasKey("tokens")
    ## while config_schema keeps REQUIRING it, because the runner injects it.
    check "tokens" in m["game"]["config_schema"]["required"].getElems().mapIt(
      it.getStr())

  test "both declared players are seated in the certification fixture":
    let m = manifest()
    check m["player"].len == 2
    var ids: seq[string]
    for entry in m["player"]:
      ids.add(entry["id"].getStr())
      check entry["type"].getStr() == "player"
      check entry["name"].getStr().len > 0
      check entry["description"].getStr().len > 0
      check entry["run"][0].getStr() == "/bin/gen-generals-io-player"
      check entry["resources"]["limits"]["cpu"].getStr() == "1"
    var seated: seq[string]
    for entry in m["certification"]["players"]:
      seated.add(entry["player_id"].getStr())
    for id in ids:
      check id in seated
    check m["certification"]["players"].len == 4
    check m["certification"]["game_config"]["players"].len == 4

  test "every array in config_schema declares minItems and maxItems":
    let m = manifest()
    for name, property in m["game"]["config_schema"]["properties"]:
      if property{"type"}.getStr() == "array":
        check property.hasKey("minItems")
        check property.hasKey("maxItems")

  test "the top-level shape the 0.1.42 upload contract wants":
    let m = manifest()
    check m.hasKey("$schema")
    check m["tags"].len >= 3
    check m["episode_timeout_minutes"].getInt() == 20
    check not m["game"].hasKey("tags")
    check not m.hasKey("version")
    check not m.hasKey("replay_viewer")
    check not m["game"].hasKey("display_name")
    check m["game"]["description"].getStr().len > 0
    check m["game"]["owner"].getStr().len > 0
    check m["game"]["runnable"]["type"].getStr() == "game"
    check m["game"]["replay_viewer"]["bundle"].getStr() ==
      "static-replay-viewer"

  test "protocols carry BOTH player and global as {type,value} objects":
    let m = manifest()
    for key in ["player", "global"]:
      let entry = m["game"]["protocols"][key]
      check entry["type"].getStr() == "text"
      check entry["value"].getStr().len > 200

  test "docs carry a readme and three text pages":
    let m = manifest()
    check m["game"]["docs"]["readme"]["type"].getStr() == "text"
    check m["game"]["docs"]["readme"]["value"].getStr().len > 200
    check m["game"]["docs"]["pages"].len == 3
    for page in m["game"]["docs"]["pages"]:
      check page["id"].getStr().len > 0
      check page["title"].getStr().len > 0
      check page["content"]["type"].getStr() == "text"
      check page["content"]["value"].getStr().len > 200

  test "every variant's wallClockBudgetSeconds is inside 60% of the timeout":
    let m = manifest()
    for variant in m["variants"]:
      check variant["game_config"]["wallClockBudgetSeconds"].getInt() <= 660
    check m["certification"]["game_config"]["wallClockBudgetSeconds"].getInt() <=
      660

  test "the secret namespace equals game.name":
    let m = manifest()
    let name = m["game"]["name"].getStr()
    check name == GameName
    check m["game"]["runnable"]["env"]["ANTHROPIC_API_KEY_URI"].getStr() ==
      "secret://coworld/" & name & "/anthropic_api_key"

  test "results_schema keys equal generalsResultsJson's keys, both ways":
    let m = manifest()
    var config = defaultGameConfig()
    config.players = @[]
    for seat in 0 ..< Seats:
      config.players.add(PlayerConfig(name: "seat-" & $seat))
    var sim = gensim.initSim(config)
    sim.finish("complete", "full_time")
    let results = generalsResultsJson(sim)
    let schema = m["game"]["results_schema"]["properties"]
    for key, _ in results:
      check schema.hasKey(key)
    for key, _ in schema:
      check results.hasKey(key)
    check m["game"]["results_schema"]["additionalProperties"].getBool() == false
    for key in ["names", "scores", "win", "reason", "endRule", "rank", "land",
        "turnsPlayed"]:
      check key in m["game"]["results_schema"]["required"].getElems().mapIt(
        it.getStr())
    check m["game"]["results_schema"]["properties"]["reason"]["enum"].len == 3
    check m["game"]["results_schema"]["properties"]["endRule"]["enum"].len == 5
    ## every seat-indexed array is bounded to exactly four entries
    for key in SeatIndexedResultsKeys:
      check schema[key]["minItems"].getInt() == 4
      check schema[key]["maxItems"].getInt() == 4
      check results[key].len == 4

  test "config_schema covers every field sim_config.update reads":
    let m = manifest()
    let properties = m["game"]["config_schema"]["properties"]
    let source = repoFile("src/generals/sim_config.nim")
    var read: seq[string]
    for line in source.splitLines():
      let trimmed = line.strip()
      for prefix in ["intField(\"", "boolField(\"", "node.hasKey(\""]:
        if trimmed.startsWith(prefix):
          let rest = trimmed[prefix.len .. ^1]
          let name = rest.split('"')[0]
          if name notin read:
            read.add(name)
    for name in read:
      check properties.hasKey(name)
    for name, _ in properties:
      ## `tokens`, `players` and `model` are read by their own branches
      ## (a token list, a player list and a string), and `slots` is
      ## runner-managed metadata the engine never reads.
      if name in ["slots", "tokens", "players", "model"]:
        continue
      check name in read
    check properties.hasKey("tokens")
    check properties.hasKey("players")
    check properties.hasKey("model")
    check "node.hasKey(\"tokens\")" in source
    check "node.hasKey(\"players\")" in source
    check "node.hasKey(\"model\")" in source

  test "the image placeholder derives from the compose service name":
    let compose = repoFile("compose.yaml")
    check "gen_generals_io:" in compose
    check "image: coworld-gen-generals-io:latest" in compose
    check "platform: linux/amd64" in compose
    check "network: host" in compose
    let m = manifest()
    check m["game"]["runnable"]["image"].getStr() == "{{GEN_GENERALS_IO_IMAGE}}"
    for entry in m["player"]:
      check entry["image"].getStr() == "{{GEN_GENERALS_IO_IMAGE}}"

  test "the runnable and every policy point at the docker_smoke defaults":
    let m = manifest()
    check m["game"]["runnable"]["run"][0].getStr() == "/bin/gen-generals-io"
    let policies = parseJson(repoFile("tools/ci/policies.json"))
    check policies.len == 4
    var prompts = 0
    var scripted = 0
    for policy in policies:
      check policy["run"].getStr() == "/bin/gen-generals-io-player"
      check policy["name"].getStr().startsWith("gen-generals-io-")
      if policy["env"].hasKey("PLAYER_PROMPT"):
        prompts.inc
        check policy["env"]["PLAYER_PROMPT"].getStr().len > 200
      if policy["env"].hasKey("PLAYER_SCRIPTED"):
        scripted.inc
        check policy["env"]["PLAYER_SCRIPTED"].getStr() in ["sprawl", "crown"]
    check prompts == 2
    check scripted == 2
    ## Champion #2 is uploaded while daveey-1 is the active player.
    check policies[1]["player"].getStr() ==
      "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"

  test "EVERY variant's game_config constructs and generates its board":
    let m = manifest()
    for variant in m["variants"]:
      var config = defaultGameConfig()
      var node = variant["game_config"]
      node["tokens"] = %["a", "b", "c", "d"]
      config.update($node)
      config.validate()
      let board = generateBoard(config)
      check board.w == config.boardW
      check board.h == config.boardH
      check board.countKind(ckCity) == config.cityCount
      check board.mountainSymmetric()
      check board.allReachable()
      let qw = config.boardW div 2
      let qh = config.boardH div 2
      check board.countKind(ckMountain) <=
        ((qw * qh * config.mountainPct) div 100) * 4
      var sim = gensim.initSim(config)
      for turn in 0 ..< 12:
        sim.stepTurn()
      check sim.turn == 12
    var certConfig = defaultGameConfig()
    var certNode = m["certification"]["game_config"]
    certNode["tokens"] = %["a", "b", "c", "d"]
    certConfig.update($certNode)
    certConfig.validate()
    check certConfig.seed == 42
