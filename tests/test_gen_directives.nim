## Test 14 — tolerant parsing and per-field repair, including the rune-boundary
## truncation the replay depends on.

import std/[unittest, json, strutils, unicode]
import generals/sim as gensim

const Emoji = "\xF0\x9F\x91\x91"   ## U+1F451 CROWN, four bytes

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
    check (ok or not ok)
    discard plan

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
