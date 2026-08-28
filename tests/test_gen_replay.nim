## Tests 18, 19 and 20 — an end-to-end episode that writes a replay, the
## record→re-derive round trip for EVERY end reason, the strict-UTF-8 parse,
## and the GameVersion sweep.

import std/[unittest, json, os, osproc, strutils, unicode, tables]
import generals/sim as gensim
import generals/roster
import generals/replays
import generals/replay_runtime

const Emoji = "\xF0\x9F\x91\x91"

proc freshSim(seed = 1734029581, startWait = -1): Sim =
  var config = defaultGameConfig()
  config.seed = seed
  if startWait >= 0:
    config.startWaitTicks = startWait
  config.players = @[]
  for seat in 0 ..< Seats:
    config.players.add(PlayerConfig(name: "seat-" & $seat))
  gensim.initSim(config)

proc recordEpisode(seed: int, kinds: array[Seats, ScriptKind],
    stopAt = -1, faultAt = -1, notes = false,
    startWait = -1): (string, Sim) =
  ## Exactly what `server.nim` writes, minus the sockets.
  var sim = freshSim(seed, startWait)
  var writer = initReplayWriter(sim.config.configJson())
  for seat in 0 ..< Seats:
    writer.writeJoin(seat, sim.names[seat], "")
    writer.writeChat("register", %*{
      "seat": seat, "alias": cogAlias(seat),
      "policy": "policy-" & $seat,
      "kind": (if seat < 2: "llm" else: "scripted"),
      "baseline": $kinds[seat]})
  writer.writeHash(sim.turn, sim.gameHash())
  while not sim.done:
    if stopAt >= 0 and sim.turn >= stopAt:
      writer.writeChat("stop", %*{"turn": sim.turn, "endRule": "wall_clock"})
      sim.applyWallClockStop(sim.turn)
      break
    if faultAt >= 0 and sim.turn == faultAt:
      sim.stopDetail = "forced guard trip"
      sim.finish("fault", "sim_fault")
      break
    if sim.isDirectiveTurn():
      for seat in sim.aliveSeats():
        var plan = scriptedPlan(sim.viewOf(seat), kinds[seat])
        if notes:
          var note = ""
          for i in 0 ..< (MaxNoteRunes - 1):
            note.add("x")
          note.add(Emoji)
          plan.note = note
        sim.installPlan(seat, plan, psScripted, 0)
        writer.writePlanInput(sim.turn, seat, planJson(plan))
        var record = %*{
          "turn": sim.turn, "seat": seat, "alias": cogAlias(seat),
          "source": "scripted", "latency_ms": 0,
          "note": truncateRunes(plan.note, MaxNoteRunes)}
        for key, value in planJson(plan):
          record[key] = value
        writer.writeChat("plan", record)
    sim.stepTurn()
    writer.writeHash(sim.turn, sim.gameHash())
  sim.endSummary()
  writer.writeChat("result", generalsResultsJson(sim))
  (writer.bytes(), sim)

suite "the replay round trip":
  test "a full scripted episode writes a COWLDGEN replay that parses":
    let (bytes, sim) = recordEpisode(1734029581,
      [skSprawl, skCrown, skSprawl, skCrown])
    check bytes.len > 1000
    check bytes.startsWith(ReplayMagic)
    let data = parseReplayBytes(bytes)
    check data.gameName == GameName
    check data.gameVersion == GameVersion
    check data.config["seed"].getInt() == sim.config.seed
    check data.joinNames().len == Seats
    check data.planRecords().len > 0
    check data.chatRecords("result").len == 1

  test "re-simulating from the plans alone reproduces EVERY recorded hash":
    for reason in ["conquest_or_full_time", "wall_clock", "sim_fault"]:
      let stopAt = if reason == "wall_clock": 96 else: -1
      let faultAt = if reason == "sim_fault": 120 else: -1
      let (bytes, sim) = recordEpisode(1734029581,
        [skSprawl, skCrown, skSprawl, skCrown], stopAt, faultAt)
      let data = parseReplayBytes(bytes)
      var session = initReplaySession(data)
      session.seekTo(session.endTick)
      check session.player.hashMismatchTick == -1
      if reason == "wall_clock":
        ## The stop turn INCLUDED: a wall-clock fact no re-simulation can
        ## derive, applied on both sides by one proc.
        check session.sim.reason == "deadline"
        check session.sim.endRule == "wall_clock"
        check session.sim.turn == 96
      elif reason == "conquest_or_full_time":
        check sim.reason == "complete"
        check session.sim.turn == sim.turn

  test "a conquest episode round-trips too":
    var seedFound = -1
    for seed in [31337, 4242, 99, 7]:
      let (bytes, sim) = recordEpisode(seed, [skSprawl, skSprawl, skCrown, skCrown])
      if sim.endRule != "conquest":
        continue
      seedFound = seed
      let data = parseReplayBytes(bytes)
      var session = initReplaySession(data)
      session.seekTo(session.endTick)
      check session.player.hashMismatchTick == -1
      break
    check seedFound >= 0

  test "the bytes alone yield names, aliases, kinds, config, seed and result":
    let (bytes, sim) = recordEpisode(42, [skSprawl, skCrown, skSprawl, skCrown])
    let data = parseReplayBytes(bytes)
    check data.joinNames() == @[sim.names[0], sim.names[1], sim.names[2],
      sim.names[3]]
    var kinds: seq[string]
    for record in data.chatRecords("register"):
      check record["alias"].getStr() == cogAlias(record["seat"].getInt())
      kinds.add(record["kind"].getStr())
    check kinds == @["llm", "llm", "scripted", "scripted"]
    let results = data.chatRecords("result")[0]
    check results["reason"].getStr() in LegalReasons
    check results["boardW"].getInt() == sim.board.w

  test "the results key set is exactly the manifest's results_schema":
    let (bytes, _) = recordEpisode(42, [skSprawl, skCrown, skSprawl, skCrown])
    let data = parseReplayBytes(bytes)
    let results = data.chatRecords("result")[0]
    var path = "coworld_manifest_template.json"
    if not fileExists(path):
      path = "../coworld_manifest_template.json"
    let manifest = parseJson(readFile(path))
    let schema = manifest["game"]["results_schema"]["properties"]
    var resultKeys: seq[string]
    for key, _ in results:
      if key == "k":
        continue
      resultKeys.add(key)
    var schemaKeys: seq[string]
    for key, _ in schema:
      schemaKeys.add(key)
    for key in resultKeys:
      check key in schemaKeys
    for key in schemaKeys:
      check key in resultKeys
    check resultKeys.len == ResultsKeys.len

  test "every plan record is inside its caps and the stream is complete":
    let (bytes, _) = recordEpisode(42, [skSprawl, skCrown, skSprawl, skCrown],
      notes = true)
    let data = parseReplayBytes(bytes)
    for record in data.chatRecords("plan"):
      check record["note"].getStr().runeLen <= MaxNoteRunes
      check record["alias"].getStr().len > 0
      check record["intent"].getStr().len <= MaxIntentRunes
    for record in data.chatRecords("register"):
      check record["policy"].getStr().runeLen <= MaxPolicyLabelRunes
    var hashes = 0
    for record in data.records:
      if record.kind == RecHash:
        hashes.inc
    check hashes > 200

  test "the derived stream carries every documented beat kind":
    let (bytes, _) = recordEpisode(42, [skSprawl, skCrown, skSprawl, skCrown])
    let data = parseReplayBytes(bytes)
    var session = initReplaySession(data)
    var seen = initTable[string, int]()
    while session.cursor < session.endTick:
      session.seekTo(session.cursor + 1)
      for event in session.sim.frameEvents:
        let kind = event{"k"}.getStr()
        seen[kind] = seen.getOrDefault(kind) + 1
    check seen.getOrDefault("claim") >= 1
    check seen.getOrDefault("growth") >= 1
    check seen.getOrDefault("citytaken") >= 1
    check seen.getOrDefault("generalspotted") >= 1

suite "playback opens at the game start":
  ## Acceptance checklist 13, third bullet. The probe is a replay whose game
  ## start is LATE — 300 presentation ticks of lobby prefix instead of the
  ## shipped 48 — because a 1-tick lobby cannot show a runtime that dwells
  ## through the prefix (cogame-pommerman / cogame-magent-battle, 2026-08-27).
  test "the cursor opens at startTick and every seek is clamped there":
    let (bytes, _) = recordEpisode(1734029581,
      [skSprawl, skCrown, skSprawl, skCrown], startWait = 300)
    let data = parseReplayBytes(bytes)
    var session = initReplaySession(data)
    check session.startTick == 300
    check session.cursor == session.startTick
    check session.sim.phase == phPlaying
    ## The restart control and the `,` key.
    session.applyCommand(",")
    check session.cursor == session.startTick
    ## A scrub click landing anywhere in the prefix, and step-back at the open.
    session.seekTo(0)
    check session.cursor == session.startTick
    session.seekTo(-500)
    check session.cursor == session.startTick
    session.applyCommand("b")
    check session.cursor == session.startTick
    ## The loop wrap.
    session.loop = true
    session.playing = true
    session.seekTo(session.endTick)
    session.advance()
    check session.cursor == session.startTick

  test "playing forward moves the board on the very first frames":
    let (bytes, _) = recordEpisode(1734029581,
      [skSprawl, skCrown, skSprawl, skCrown], startWait = 300)
    var session = initReplaySession(parseReplayBytes(bytes))
    let openingHash = session.sim.gameHash()
    for i in 0 ..< 3:
      session.advance()
    check session.sim.turn == 3
    check session.sim.gameHash() != openingHash

  test "the hash-checked re-simulation still runs every recorded frame":
    let (bytes, sim) = recordEpisode(1734029581,
      [skSprawl, skCrown, skSprawl, skCrown], startWait = 300)
    var session = initReplaySession(parseReplayBytes(bytes))
    session.seekTo(session.endTick)
    check session.player.hashMismatchTick == -1
    check session.sim.turn == sim.turn

suite "strict UTF-8 forensics":
  test "replay_summary.py parses a replay whose caps are full of emoji":
    let (bytes, _) = recordEpisode(42, [skSprawl, skCrown, skSprawl, skCrown],
      notes = true)
    let path = getTempDir() / "gen_generals_io_test.replay"
    writeFile(path, bytes)
    var script = "tools/replay_summary.py"
    if not fileExists(script):
      script = "../tools/replay_summary.py"
    check fileExists(script)
    let (output, code) = execCmdEx("python3 " & quoteShell(script) & " " &
      quoteShell(path))
    check code == 0
    check output.validateUtf8() == -1
    let summary = parseJson(output)
    check summary["protocol"].getStr() == "gen-generals-io/v1"
    check summary["gameVersion"].getStr() == GameVersion
    check summary["results"]["reason"].getStr() in LegalReasons
    check summary["plans"].len > 0
    var withNotes = 0
    for plan in summary["plans"]:
      let note = plan["note"].getStr()
      if note.len > 0:
        withNotes.inc
        check note.runeLen <= MaxNoteRunes
        check note.validateUtf8() == -1
    check withNotes > 0
    ## The embedded config JSON decodes strictly too.
    check ($summary["config"]).validateUtf8() == -1
    removeFile(path)

suite "the GameVersion sweep":
  test "every committed fixture carries the current GameVersion":
    var path = "tools/ci/check_gameversion.sh"
    if not fileExists(path):
      path = "../tools/ci/check_gameversion.sh"
    check fileExists(path)
    check "src/generals/sim_types.nim" in readFile(path)
    var types = "src/generals/sim_types.nim"
    if not fileExists(types):
      types = "../src/generals/sim_types.nim"
    check ("GameVersion* = \"" & GameVersion & "\"") in readFile(types)
    ## Every replay this repo writes carries it in its header.
    let (bytes, _) = recordEpisode(42, [skSprawl, skCrown, skSprawl, skCrown])
    check parseReplayBytes(bytes).gameVersion == GameVersion
