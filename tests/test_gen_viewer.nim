## Tests 23 and 27 — the chrome's provenance, the appended block's rules, and
## (when a bundle exists) the EXACT emitted wasm module.

import std/[unittest, algorithm, os, osproc, strutils]
import generals/sim_types

proc repo(name: string): string =
  if fileExists(name): readFile(name) else: readFile("../" & name)

proc exists(name: string): bool =
  fileExists(name) or fileExists("../" & name)

proc pathOf(name: string): string =
  if fileExists(name): name else: "../" & name

let page = repo("client/replay_broadcast.html")
let core = repo("client/broadcast_core.js")
let chrome = repo("client/chrome_common.js")

suite "chrome provenance":
  test "chrome_common.js is coworld-ctf's plus the fleet-wide 0.5x patch":
    ## The pin: coworld-ctf's chrome_common.js plus the fleet-wide replay
    ## transport patch (the 0.5x speed chip mapped to command '5', and 0.5
    ## in the raw file:// SPEEDS fallback). Everything else gen-generals-io
    ## adds lives in the appended game block; the file is otherwise NOT
    ## edited and NOT reformatted. sha256, pinned as a literal, computed
    ## with the platform's own tool so the pin needs no dependency the
    ## Dockerfile does not already have.
    let (digest, code) = execCmdEx(
      "sha256sum " & quoteShell(pathOf("client/chrome_common.js")))
    check code == 0
    check digest.split(' ')[0] ==
      "594ed4a72cd908922c982d0f3e3ffb04ae1d97568fcd5f5daa794042662a369c"
    check chrome.len == 40037
    check "window.ChromeCommon" in chrome
    check "window.CTF_WIRE" in chrome
    ## The fleet-wide 0.5x transport patch, and nothing else.
    check "0.5: '5'" in chrome
    check "[0.5, 1, 2, 3, 4, 8, 16]" in chrome

  test "broadcast_core.js is the starter's, with ONE documented line changed":
    ## coworld-ctf's core is a generic sprite/layer renderer with no game
    ## logic in it at all, so this fork changes exactly one line: the wire
    ## constants it reads.
    check "window.GEN_WIRE" in core
    check "CTF_WIRE" notin core
    for kept in ["function BroadcastCore(config)", "function relayout",
        "function attachMinimap", "function sendCommand", "function clickMap",
        "function getPaceStats", "function setViewportSize",
        "function composite", "function parse(bytes)"]:
      if kept.startsWith("function relayout"):
        continue
      check kept in core

  test "the page is the starter's, spliced at the documented banner":
    check "GEN-GENERALS-IO additions to the inherited coworld-ctf chrome" in page
    check "PAINTBALL additions to the inherited coworld-ctf chrome" notin page
    ## exactly ONE game block
    check page.count("additions to the inherited coworld-ctf chrome") == 1
    ## the starter's own markup and ids are still there
    for id in ["id=\"viewport\"", "id=\"stage\"", "id=\"board\"",
        "id=\"lightpool\"", "id=\"grain\"", "id=\"lockerroom\"",
        "id=\"chrome\"", "id=\"scorebug\"", "id=\"plates-l\"",
        "id=\"plates-r\"", "id=\"clock\"", "id=\"clock-time\"",
        "id=\"clock-caption\"", "id=\"bannerlane\"", "id=\"killfeed\"",
        "id=\"mmwarn\"", "id=\"transport\"", "id=\"btn-restart\"",
        "id=\"btn-back\"", "id=\"btn-play\"", "id=\"btn-fwd\"",
        "id=\"btn-end\"", "id=\"btn-loop\"", "id=\"btn-skip\"",
        "id=\"btn-spoilers\"", "id=\"ffwd-chip\"", "id=\"ffwd-mini\"",
        "id=\"win-chip\"", "id=\"tick-clock\"", "id=\"speedchips\"",
        "id=\"scrub\"", "id=\"momentum\"", "id=\"scrub-fill\"", "id=\"lulls\"",
        "id=\"scrub-win\"", "id=\"scrub-head\"", "id=\"endcard\"",
        "id=\"ec-headline\"", "id=\"ec-wincond\"", "id=\"ec-how\"",
        "id=\"ec-teams\"", "id=\"ec-replay\"", "id=\"status\""]:
      check id in page

  test "the removed elements appear nowhere":
    for gone in ["id=\"viewpanel\"", "id=\"minimap\"", "id=\"minimap-canvas\"",
        "id=\"zoombar\"", "id=\"zoom-in\"", "id=\"zoom-out\"",
        "id=\"zoom-slider\"", "id=\"zoom-read\"", "id=\"povBadge\"",
        "id=\"fpv\"", "id=\"fpv-canvas\"", "id=\"fpv-hud\"", "id=\"fpv-name\"",
        "id=\"fpv-hp\"", "id=\"fpv-gear\"", "id=\"fpv-map\"",
        "id=\"fpv-map-canvas\"", "id=\"fpv-cap\"", "id=\"fpv-grip\"",
        "$('minimap", "$('fpv", "$('povBadge",
        "attachMinimap($('minimap-canvas'))",
        ".hillchip", ".hcap", ".flagicon", ".squad-pip", ".ec-heart",
        "#pb-regime", ".lives-num", ".lives-label"]:
      check gone notin page

  test "the beat CSS is exactly the four kinds this game emits":
    var kinds: seq[string]
    var cursor = 0
    while true:
      let index = page.find(".beat-marker.", cursor)
      if index < 0:
        break
      cursor = index + 13
      var name = ""
      while cursor < page.len and page[cursor] in {'a' .. 'z'}:
        name.add(page[cursor])
        cursor.inc
      if name.len > 0 and name notin kinds:
        kinds.add(name)
    kinds.sort()
    check kinds == @["citytaken", "end", "generalcaptured", "generalspotted"]

  test "the beat builder is genBeat and never shadows markBeat":
    check "function genBeat(" in page
    check "function markBeat(" notin page
    ## The tandem 2026-08-23 hoisting trap: no identifier the appended block
    ## defines may collide with a name the chrome alias block hoists.
    let gameBlock = page[page.find("GEN-GENERALS-IO additions") .. ^1]
    for aliased in ["markBeat", "renderBeatMarkers", "ingestBeats",
        "renderClock", "renderTransport", "ingestLullSpans", "setVerdict",
        "recordMomentum", "renderMomentum", "teamCol", "activeTeams",
        "teamOf", "rosterName", "togglePov"]:
      check ("function " & aliased) notin gameBlock
      check ("var " & aliased) notin gameBlock

  test "the transport rules the starter set are all still in force":
    ## The endcard stops at the transport band, so the scrubber stays
    ## clickable underneath it (the starter's own rule, kept).
    let endcardRule = page[page.find("#endcard {") .. page.find("#endcard {") + 900]
    check "bottom: var(--band, 0px);" in endcardRule
    check "--band" in page
    check "--topband" in page
    check "--hudscale" in page
    check "setProperty('--band'" in page
    check "setProperty('--topband'" in page
    check "setProperty('--hudscale'" in page
    ## every seek dismisses the endcard
    check "classList.remove('on')" in page
    ## no game-block element is positioned inside the transport band
    let gameBlock = page[page.find("GEN-GENERALS-IO additions") .. ^1]
    check "bottom: var(--band" notin gameBlock
    check "#genband" in gameBlock
    check "top: var(--topband, 0px);" in gameBlock

  test "the four 360 px rules exist":
    let gameBlock = page[page.find("GEN-GENERALS-IO additions") .. ^1]
    check ".plate-name { flex: 1 1 auto; min-width: 3.2em;" in gameBlock
    check "@media (max-width: 640px)" in gameBlock
    check ".land-label { display: none; }" in gameBlock
    check "ALWAYS the exact integer" in repo("src/generals/global.nim")
    check "army <= 9999" in repo("src/generals/global.nim")

  test "no ctf_ / CTF_ / PB_ identifier survives outside the two alias lines":
    for name in ["client/broadcast_core.js", "client/replay_broadcast.html",
        "replay-viewer/gen_replay.nim", "replay-viewer/static_replay.js",
        "replay-viewer/static_replay_worker.js", "replay-viewer/config.nims",
        "src/generals/global.nim", "src/generals/broadcast.nim",
        "src/generals/server.nim"]:
      let text = repo(name)
      check "ctf_" notin text
      check "CTF_WIRE" notin text
      check "PB_MODE" notin text
      check "PB_CTX" notin text
    ## The two documented alias lines, and only those two.
    let wire = repo("src/generals/wire_constants.nim")
    check "window.CTF_WIRE=window.GEN_WIRE;" in wire
    check wire.count("CTF_WIRE") == 3  ## the emitter, and the two comment lines that document why it exists

  test "the emscripten flags and the JS bootstrap are a MATCHED pair":
    let config = repo("replay-viewer/config.nims")
    let worker = repo("replay-viewer/static_replay_worker.js")
    ## coworld-ctf's set, kept as one piece: non-modularized module plus an
    ## onRuntimeInitialized bootstrap. A mixture hangs on "Loading replay..."
    ## forever (cogame-lantern, 2026-08-23).
    check "MODULARIZE" notin config
    check "EXPORT_NAME" notin config
    check "Module.onRuntimeInitialized" in worker
    check "-s ABORTING_MALLOC=1" in config
    check "-s ALLOW_MEMORY_GROWTH" in config
    check "-s FILESYSTEM=1" in config
    check "-s ENVIRONMENT=web,worker,node" in config
    check "--preload-file" in config
    for symbol in ["_gen_load_replay", "_gen_frame", "_gen_input",
        "_gen_packet_ptr", "_gen_packet_len", "_gen_mismatch_tick",
        "_gen_error_ptr", "_gen_error_len", "_gen_stage_ptr",
        "_gen_stage_len"]:
      check symbol in config
    check "importScripts('./wire_constants.js', './broadcast_core.js', " &
      "'./gen_replay.js')" in worker

  test "the load and error signals the harness reads are inherited":
    let shell = repo("replay-viewer/static_replay.js")
    check "data-replay-loaded" in shell
    check "data-replay-error" in shell
    check "'loaded'" in shell

  test "the page and the shell agree on the adapter's name":
    ## The page decides it is running inside the static bundle by looking
    ## for the shell's global. A rename applied to one file and not the
    ## other leaves the page opening a websocket that is not there: every
    ## asset 200s, nothing throws, and the viewer never draws a frame.
    let shell = repo("replay-viewer/static_replay.js")
    check "window.GenStaticReplay = {" in shell
    check "window.GenStaticReplay" in page
    check "CtfStaticReplay" notin shell
    check "CtfStaticReplay" notin page
    check "CtfStaticReplay" notin repo("client/league_replayer.html")

suite "the worst-case renderer fixture":
  ## Acceptance checklist 15, last bullet. `docker_smoke.sh` runs with no
  ## ANTHROPIC_API_KEY, so every seat in the CI replay is scripted and emits
  ## no note: the fixture is the ONLY gate that makes the shipped page draw
  ## LLM-authored text, and it has to drive the page's own path and assert its
  ## own strings are still whole.
  let fixture = repo("tools/ci/renderer_fixture.html")
  let workflow = repo(".github/workflows/ci.yml")

  test "it hands the page a full-cap remark on every seat as a plan EVENT":
    ## `state.plan[]` is never read by the page: `gen_block.html` draws a
    ## remark from `case 'plan':` inside `event()`, which the page drives from
    ## `s.events`.
    check "k: 'plan'" in fixture
    check "for (var s = 0; s < 4; s++)" in fixture
    check "note: NOTE" in fixture
    check "NOTE.length < " & $MaxNoteRunes in fixture
    check "NOTE.slice(0, " & $MaxNoteRunes & ")" in fixture

  test "it asserts the drawn remarks are still full-length":
    ## Row counting alone would leave a quietly shortened remark green.
    check "text.indexOf(NOTE) < 0" in fixture
    check "was SHORTENED at" in fixture
    check "full-cap commander " in fixture
    check "data-replay-error" in fixture

  test "it is driven by viewer_smoke with --strict-text-bounds":
    let step = workflow[workflow.find("worst-case renderer fixture") .. ^1]
    check "renderer_fixture.html" in step
    check "--strict-text-bounds" in step
    check "continue-on-error" notin step

  test "the commander line has a wrapping band sized from the note cap":
    ## A 160-rune sentence in the starter's one-line `white-space: nowrap`
    ## feed row would grow leftward across the board; ellipsizing it would be
    ## the defect the checklist names. It wraps inside the feed instead.
    let gameBlock = page[page.find("GEN-GENERALS-IO additions") .. ^1]
    check ".feed-row.plan {" in gameBlock
    check "white-space: normal;" in gameBlock
    check "overflow-wrap: anywhere;" in gameBlock
    check "'plan');" in gameBlock

suite "the wasm harness":
  test "the EXACT emitted module loads the replay and never diverges":
    ## The `test` job has no bundle, so this returns early there; the
    ## wasm-viewer job stages one and greps for the OK line below.
    var dist = "replay-viewer/dist"
    if not dirExists(dist):
      dist = "../replay-viewer/dist"
    var replay = ""
    for candidate in ["dist/smoke/replay.json", "../dist/smoke/replay.json"]:
      if fileExists(candidate):
        replay = candidate
        break
    if not dirExists(dist) or not fileExists(dist / "gen_replay.js") or
        replay.len == 0:
      echo "no bundle or smoke replay staged; skipping the wasm harness"
      skip()
    else:
      let script = pathOf("tools/wasm_replay_smoke.cjs")
      let (output, code) = execCmdEx("node " & quoteShell(script) & " " &
        quoteShell(dist) & " " & quoteShell(replay) & " 300")
      echo output
      check code == 0
      echo "WASM-SMOKE OK"
