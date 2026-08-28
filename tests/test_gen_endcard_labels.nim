## Test 24 — the endcard and chrome label re-mapping.
##
## A forked ctf endcard silently ships paintbot's vocabulary, and nothing in
## the starter's tests, in viewer_smoke.mjs or in the label manifest covers
## spectator chrome strings. This is the gate.

import std/[unittest, os, strutils]

proc repo(name: string): string =
  if fileExists(name): readFile(name) else: readFile("../" & name)

proc stripComments(text: string): string =
  ## Comment blocks are exempt: the page documents its own history, and this
  ## test is about what a SPECTATOR reads.
  var kept = ""
  var i = 0
  while i < text.len:
    if i + 3 < text.len and text[i .. i + 3] == "<!--":
      let close = text.find("-->", i)
      i = if close < 0: text.len else: close + 3
    elif i + 1 < text.len and text[i .. i + 1] == "/*":
      let close = text.find("*/", i)
      i = if close < 0: text.len else: close + 2
    elif i + 1 < text.len and text[i .. i + 1] == "//":
      let close = text.find("\n", i)
      i = if close < 0: text.len else: close
    else:
      kept.add(text[i])
      i.inc
  kept

proc spectatorStrings(text: string): string =
  ## Everything a spectator can actually READ: the HTML text nodes and the
  ## quoted string literals. Identifiers (`layer.flags`, `ZoomableFlag`) are
  ## not vocabulary, and comment blocks are exempt by stripComments above.
  var kept = ""
  var i = 0
  while i < text.len:
    let ch = text[i]
    if ch == '"' or ch == '\'':
      let quote = ch
      i.inc
      while i < text.len and text[i] != quote:
        if text[i] == '\\':
          i.inc
        if i < text.len:
          kept.add(text[i])
          i.inc
      kept.add(' ')
      i.inc
    elif ch == '>':
      i.inc
      while i < text.len and text[i] != '<':
        kept.add(text[i])
        i.inc
      kept.add(' ')
    else:
      i.inc
  kept

suite "spectator vocabulary":
  test "the forbidden vocabulary appears in no spectator-facing string":
    for name in ["client/replay_broadcast.html", "client/broadcast_core.js"]:
      let text = spectatorStrings(stripComments(repo(name)))
      for word in ["Lives", "LIVES", "Clstr", "flagicon", "heart", "paint",
          "hopper", "hill", "POV", "spray", "grenade", "med kit", "kills",
          " killed", "Tags", "Hill time", "Cog"]:
        if word in text:
          checkpoint(name & " still says " & word)
        check word notin text

  test "each replacement is present exactly once":
    let page = repo("client/replay_broadcast.html")
    for wanted in [
        "<span>Commander</span>",
        "<span class=\"land-label\">Land</span>",
        "<span class=\"momentum-label\">LAND</span>",
        "Raising the standards&hellip;",
        ">Four crowns, one map<"]:
      check page.count(wanted) == 1
    check page.count("<span>Land</span>") == 1
    check page.count("<span>Army</span>") == 1
    check page.count("<span>Cities</span>") == 1
    check page.count("<span>Crowns</span>") == 1
    check "Replay hash mismatch" in page
    check "showing recorded plans" in page
    check "cities / crowns found / crowns taken / winner on the timeline" in page
