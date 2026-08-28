## Test 14 — tolerant parsing and per-field repair, including the rune-boundary
## truncation the replay depends on.

import std/[unittest, json, strutils, unicode]
import generals/sim as gensim

const Emoji = "\xF0\x9F\x91\x91"   ## U+1F451 CROWN, four bytes

suite "the system prompt":
  test "every clock in the prompt comes from the config, not from ffa":
    ## `blitz` plays 160 turns with a growth beat every 15; a prompt that
    ## still said "turn 240" and "every 25 turns" would describe a different
    ## game from the one the observation JSON reports every turn.
    var ffa = defaultGameConfig()
    let ffaPrompt = systemPromptFor(ffa)
    check "16 by 10" in ffaPrompt
    check "turn " & $ffa.maxTurns in ffaPrompt
    check "every " & $ffa.growthPeriod & " turns" in ffaPrompt
    check "Every " & $ffa.directiveEvery & " turns" in ffaPrompt
    check "city holds " & $ffa.cityArmy in ffaPrompt

    var blitz = defaultGameConfig()
    blitz.boardW = 12
    blitz.boardH = 8
    blitz.maxTurns = 160
    blitz.growthPeriod = 15
    blitz.directiveEvery = 6
    blitz.cityArmy = 50
    let blitzPrompt = systemPromptFor(blitz)
    check "12 by 8" in blitzPrompt
    check "turn 160" in blitzPrompt
    check "every 15 turns" in blitzPrompt
    check "Every 6 turns" in blitzPrompt
    check "city holds 50" in blitzPrompt
    check "turn 240" notin blitzPrompt
    check "every 25 turns" notin blitzPrompt
    ## and no substitution token survives into what a model reads
    for token in ["WxH", "CITYARMY", "GROWTHEVERY", "PLANEVERY", "MAXTURNS"]:
      check token notin ffaPrompt
      check token notin blitzPrompt

suite "parsing an LLM reply":
  test "prose-prefixed and fenced JSON are both recovered":
    var repaired = 0
    let previous = defaultPlanValue()
    for text in [
        "Sure! Here is my plan:\n{\"intent\":\"raid\",\"scouts\":2}",
        "```json\n{\"intent\":\"raid\",\"scouts\":2}\n```",
        "{\"intent\":\"raid\",\"scouts\":2} — hope that helps"]:
      let (plan, ok) = parsePlan(text, previous, false, repaired)
      check ok
      check plan.intent == inRaid
      check plan.scouts == 2

  test "numeric strings, hyphenated enums and unknown intents are repaired":
    var repaired = 0
    let previous = defaultPlanValue()
    var (plan, ok) = parsePlan(
      "{\"intent\":\"Fall-Back\",\"reserve\":\"25\",\"scouts\":\"1\"}",
      previous, false, repaired)
    check ok
    check plan.intent == inExpand        ## unknown -> expand with no history
    check plan.reserve == 25
    check plan.scouts == 1
    check repaired >= 1
    var last = defaultPlanValue()
    last.intent = inRaid
    (plan, ok) = parsePlan("{\"intent\":\"nonsense\"}", last, true, repaired)
    check ok
    check plan.intent == inRaid          ## unknown -> keep last turn's

  test "out-of-domain numbers are clamped, not rejected":
    var repaired = 0
    let previous = defaultPlanValue()
    let (plan, ok) = parsePlan(
      "{\"reserve\":5000,\"scouts\":9,\"target\":[99,-4]}",
      previous, false, repaired)
    check ok
    check plan.reserve == 999
    check plan.scouts == 3
    let clamped = clampPlan(plan, 16, 10)
    check clamped.targetX == 15
    check clamped.targetY == 0

  test "a negative reserve clamps to zero":
    var repaired = 0
    let (plan, ok) = parsePlan("{\"reserve\":-3}", defaultPlanValue(), false,
      repaired)
    check ok
    check plan.reserve == 0

  test "an {x,y} target object is accepted":
    var repaired = 0
    let (plan, ok) = parsePlan("{\"target\":{\"x\":3,\"y\":4}}",
      defaultPlanValue(), false, repaired)
    check ok
    check plan.hasTarget
    check plan.targetX == 3
    check plan.targetY == 4

  test "a reply with ONLY a note is usable and keeps the current plan":
    var repaired = 0
    var last = defaultPlanValue()
    last.intent = inGather
    last.reserve = 12
    let (plan, ok) = parsePlan("{\"note\":\"holding the line\"}", last, true,
      repaired)
    check ok
    check plan.intent == inGather
    check plan.reserve == 12
    check plan.note == "holding the line"

  test "a non-object reply is a parse failure":
    var repaired = 0
    for text in ["not json at all", "[1,2,3]", ""]:
      let (_, ok) = parsePlan(text, defaultPlanValue(), false, repaired)
      check not ok

  test "a 9 KB reply is capped at 4096 bytes and then parsed":
    var repaired = 0
    var padding = ""
    while padding.len < 9000:
      padding.add("filler ")
    let text = "{\"intent\":\"scout\",\"note\":\"" & padding & "\"}"
    check text.len > 9000
    let (plan, ok) = parsePlan(text, defaultPlanValue(), false, repaired)
    ## The read is truncated first, so what survives is at most the cap.
    check extractJsonObject(text).len <= MaxReplyBytes
    ## The cut lands inside the note, so the object never closes: this is a
    ## parse FAILURE that keeps the seat's previous plan, not a crash and not
    ## a half-applied plan. (The caller retries once, then falls back.)
    check not ok
    check plan == defaultPlanValue()
    ## And the cap does not stop a reply whose object fits: 9 KB of prose
    ## AFTER a small object still parses.
    let tail = "{\"intent\":\"scout\",\"scouts\":3} " & padding
    let (tailPlan, tailOk) = parsePlan(tail, defaultPlanValue(), false,
      repaired)
    check tailOk
    check tailPlan.intent == inScout
    check tailPlan.scouts == 3

  test "the 4096 reply cap is BYTES, cut on a rune boundary":
    ## The note states this one cap in BYTES. Under a rune cap a reply of
    ## four-byte runes survived at up to 16 KB.
    var wide = ""
    while wide.len < 12000:
      wide.add(Emoji)
    let cut = truncateBytes(wide, MaxReplyBytes)
    check cut.len <= MaxReplyBytes
    check cut.len > MaxReplyBytes - 4
    check cut.validateUtf8() == -1
    check truncateBytes("abc", 10) == "abc"
    check extractJsonObject("{\"note\":\"" & wide & "\"}").len <= MaxReplyBytes

  test "a 300-character note truncates to 160 RUNES":
    var repaired = 0
    var long = ""
    while long.runeLen < 300:
      long.add("a")
    let (plan, ok) = parsePlan("{\"note\":\"" & long & "\"}",
      defaultPlanValue(), false, repaired)
    check ok
    check plan.note.runeLen == MaxNoteRunes

  test "a 4-byte emoji sitting ON the cap truncates on the RUNE boundary":
    ## 159 ASCII runes then the crown: the 160th rune is four bytes, and a
    ## byte-truncating cap would cut it in half. The result must still
    ## round-trip through the JSON writer and decode as strict UTF-8.
    var text = ""
    for i in 0 ..< 159:
      text.add("x")
    text.add(Emoji)
    text.add(Emoji)
    let note = sanitizeNote(text, MaxNoteRunes)
    check note.runeLen == MaxNoteRunes
    check note.len == 159 + 4
    check note.validateUtf8() == -1
    let encoded = $ %*{"note": note}
    let decoded = parseJson(encoded)
    check decoded["note"].getStr() == note
    check decoded["note"].getStr().validateUtf8() == -1

  test "every capped string truncates on runes, not bytes":
    var wide = ""
    for i in 0 ..< 60:
      wide.add(Emoji)
    check truncateRunes(wide, 10).runeLen == 10
    check truncateRunes(wide, 10).len == 40
    check truncateRunes(wide, 10).validateUtf8() == -1
    check runeCap(wide, MaxPolicyLabelRunes).runeLen == MaxPolicyLabelRunes
    check truncateRunes(wide, MaxFallbackDetailRunes).validateUtf8() == -1

  test "newlines in a note collapse to spaces":
    let note = sanitizeNote("first line\nsecond\tline", MaxNoteRunes)
    check "\n" notin note
    check "\t" notin note
    check "first line second line" == note
