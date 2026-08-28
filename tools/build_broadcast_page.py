#!/usr/bin/env python3
"""Derive client/replay_broadcast.html from coworld-ctf's page.

Usage: tools/build_broadcast_page.py <ctf page> <gen block> <out>

This is the record of the surgery the design note authorises, kept in the
repo so a reviewer can re-run it and diff the result against the starter:

  * the inherited page is coworld-ctf's `client/replay_broadcast.html`;
  * the elements design note SS Viewer lists as removed are deleted -- markup,
    CSS and the JS that feeds them: `#viewpanel` (zoom bar + minimap), `#fpv`
    and every child, `#povBadge`, the ctf scorebug internals
    (`.hillchip`, `.hcap`, `.flagicon`, `.lives-num`, `.lives-label`,
    `.squad-pip`, `.squad`, `.pb-tags`, `#pb-regime`, `.ec-heart`) and the
    beat CSS kinds this game never emits;
  * the endcard and chrome label re-mappings of SS Viewer are applied in place;
  * the starter's PAINTBALL block is removed with the paintball mechanics and
    the GEN-GENERALS-IO block takes its place, so the page carries exactly one
    game block.

Everything else -- the CSS, the markup, `relayout()`, the transport, the
endcard shell, the locker-room loader, the `?embed=1` mode and the `.tiny`
density system -- is the starter's bytes.
"""
import re
import sys
from pathlib import Path

src, block_path, out_path = (Path(a) for a in sys.argv[1:4])
text = src.read_text(encoding="utf-8")


def cut(start_marker, end_marker, replacement=""):
    global text
    start = text.index(start_marker)
    end = text.index(end_marker, start)
    text = text[:start] + replacement + text[end:]


# ---------------------------------------------------------------- markup ---
cut("    <!-- View controls: zoom the board",
    '    <div id="mmwarn">')
text = "\n".join(line for line in text.split("\n") if 'id="povBadge"' not in line)
cut("    <!-- First-person picture-in-picture",
    '    <div id="bannerlane"></div>')

# ------------------------------------------------------------------- CSS ---
DROP_SELECTOR = re.compile(
    r"(^|[\s,])(#viewpanel|#minimap|#zoombar|#zoom-in|#zoom-out|#zoom-slider|"
    r"#zoom-read|#povBadge|#fpv[a-z-]*|#pb-regime|\.zbtn|\.mm-cap|\.fpv-[a-z-]+|"
    r"\.hillchip|\.hcap|\.flagicon|\.squad|\.squad-pol|\.squad-pip|\.pb-tags|"
    r"\.pb-sub|\.pb-lbl|\.ec-heart|\.ec-heart-glyph|\.carrier-tag|"
    r"\.perk-ico|\.perk-icos|"
    r"\.beat-marker\.(kill|steal|return|capture|hillflip|hillhold|tagout|"
    r"gamestart|gameover))([\s,:.#\[{]|$)")


def strip_css(css: str) -> str:
    out, depth, buf = [], 0, ""
    for ch in css:
        buf += ch
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                selector = buf.split("{")[0]
                if DROP_SELECTOR.search(selector) and "@" not in selector:
                    buf = ""
                    continue
                out.append(buf)
                buf = ""
    out.append(buf)
    return "".join(out)


pieces, cursor = [], 0
while True:
    start = text.find("<style>", cursor)
    if start < 0:
        pieces.append(text[cursor:])
        break
    end = text.index("</style>", start)
    pieces.append(text[cursor:start + len("<style>")])
    pieces.append(strip_css(text[start + len("<style>"):end]))
    cursor = end
text = "".join(pieces)

# ------------------------------------------------------------------- JS ----
# The static minimap wall silhouette: there is no minimap.
cut("  // The server ships the static minimap wall silhouette ONCE",
    "  function seatLivesLeft(p) {",
    "  function ingestFpMap(s) { void s; }\n\n")

# The scorebug plate builders. The plate, the sides and the clock column are
# the starter's; only the CONTENTS change (design note SS Viewer).
cut("  function seatLivesLeft(p) {",
    "  function shortName(n) {",
    """  // GEN-GENERALS-IO: the plates are filled by the appended game block --
  // colour chip, the real policy name (spectator side only), land as the big
  // numeral and `army . cities` beneath it. ensureScorebug keeps the
  // starter's own per-side .plates.row four-team layout.
  var sbTeams = null;
  function ensureScorebug(teams) {
    if (sbTeams === teams.join(',')) return;
    sbTeams = teams.join(',');
    var sides = [$('plates-l'), $('plates-r')];
    sides[0].innerHTML = '';
    sides[1].innerHTML = '';
    sides[0].classList.toggle('row', teams.length > 2);
    sides[1].classList.toggle('row', teams.length > 2);
    teams.forEach(function (team, i) {
      var plate = document.createElement('div');
      plate.className = 'plate ' + team + ' ' + (i % 2 === 0 ? 'side-l' : 'side-r');
      plate.setAttribute('data-team', team);
      plate.innerHTML =
        '<div class="team-id">' +
        '<div class="plate-line">' +
        '<span class="team-name plate-name" id="name-' + team + '">' + team.toUpperCase() + '</span>' +
        '<span class="land-label">Land</span>' +
        '<span class="land-num" id="land-' + team + '">0</span>' +
        '</div>' +
        '<div class="plate-sub" id="sub-' + team + '"></div>' +
        '</div>';
      sides[i % 2].appendChild(plate);
    });
  }

  function renderScorebug(s) {
    ensureScorebug(activeTeams(s));
    if (window.GenGeneralsChrome) window.GenGeneralsChrome.scorebug(s);
  }

""")

# The flag icon builder.
cut("  // ---- flag icon svg",
    "  // (speed chips are built + rendered by the shared chrome via ctx.send)")

# The whole first-person pipeline: this game's fog is an integer set, not a
# raycast, and the fog lens replaces the PIP.
cut("  // ---------- pov + mismatch ----------",
    "  function renderMismatch(s) {",
    """  // ---------- mismatch ----------
  // GEN-GENERALS-IO: the POV lens and the first-person PIP are gone with the
  // raycast fog. The fog lens in the TOP band shows a seat's vision by
  // washing #lightpool instead, derived in the browser from `cells`.
  function renderPov(s) { void s; }

""")

# applyEvent: every beat goes through the appended game block.
cut("  function applyEvent(e, s) {",
    "  // Slots already drawn as the partner",
    """  function applyEvent(e, s) {
    // GEN-GENERALS-IO: every beat goes through the appended game block, which
    // draws LABELLED, CLICKABLE buttons on the scrubber (genBeat) instead of
    // chrome_common's unlabelled div markers.
    if (window.GenGeneralsChrome && window.GenGeneralsChrome.event(e, s, GEN_CTX)) {
      beatPulse();
    }
  }

""")

# The ctf feed writers (kills, hearts, flags).
cut("  // Slots already drawn as the partner",
    "  // (teamOf / esc live in the shared chrome")

# The ctf endcard body (lives, hearts, K/D/Clstr/Cap columns).
cut("  function overLives(o, team) {",
    "  function renderEndcard(s) {",
    """  // GEN-GENERALS-IO: the endcard table is Commander | Land | Army | Cities |
  // Crowns, built by the appended game block (design note SS Viewer,
  // "Endcard and chrome label re-mapping").
  function ingestCapHearts(s) { void s; }

""")

cut("  function renderEndcard(s) {",
    "  // ============================================================\n  //  Transport wiring",
    """  function renderEndcard(s) {
    if (!s.over) return;
    $('endcard').classList.add('on');
    if (window.GenGeneralsChrome) window.GenGeneralsChrome.endcard(s);
  }

""")

# The ?viewpanel=0 opt-out: there is no view panel to opt out of.
cut("  // ?viewpanel=0 hides the #viewpanel overlay",
    "  // Tick deep-link (?t=<tick>)")

# The POV clear button.
text = text.replace(
    "  // pov clear (togglePov lives in the shared chrome, driven via ctx.sendPov)\n"
    "  $('povBadge').addEventListener('click', function () { send('v:-1'); });\n",
    "")

# The zoom + minimap wiring.
cut("  var minimapBox = $('minimap');",
    "  canvas.addEventListener('dblclick', function (ev) {",
    """  // GEN-GENERALS-IO: #viewpanel is gone (the board is a fixed grid that
  // relayout() fits whole at every width), so there is no slider, no readout
  // and no minimap to keep in step. broadcast_core tolerates a missing
  // minimap: pendingMinimap stays null. The core's transform is still the
  // single source of truth, and the fog lens is drawn against it.
  function syncViewUi(t) {
    t = t || (core && core.getTransform ? core.getTransform() : null);
    if (window.GenGeneralsChrome) window.GenGeneralsChrome.transform(t);
    if (t) syncTouchAction(t);
  }

""")
text = text.replace("  var SLIDER_TRAVEL = 1000;\n", "")

# The paintball block, replaced by this game's one block.
marker = text.index("     PAINTBALL additions to the inherited coworld-ctf chrome")
block_start = text.rindex("<!--", 0, marker)
tail_start = text.index("</body>", block_start)
text = text[:block_start] + block_path.read_text(encoding="utf-8") + text[tail_start:]

# ------------------------------------------------- label re-mapping table ---
REPLACEMENTS = [
    ("lives-line", "plate-line"),
    ('<span class="lives-label">Lives</span>', '<span class="land-label">Land</span>'),
    ("lives-num", "land-num"),
    ("lives-label", "land-label"),
    ('<span class="momentum-label">LIVES LEAD</span>',
     '<span class="momentum-label">LAND</span>'),
    ("Filling hoppers with fresh paint&hellip;", "Raising the standards&hellip;"),
    # The rotating prep-talk line under the locker-room scene is spectator
    # text, so it is re-labelled with the rest of the vocabulary.
    ("""      'Filling hoppers with fresh paint\u2026',
      'Pump check: one, two. One, two\u2026',
      'Polishing visors to a mirror shine\u2026',
      'Shaking the paint pods awake\u2026',
      'Squats. Even robots warm up\u2026',
      'Topping off the CO\u2082\u2026',
      'Chalking up the wheels\u2026',
      'Reviewing the game plan\u2026'""",
     """      'Raising the standards\u2026',
      'Counting the garrison: one, two. One, two\u2026',
      'Polishing four crowns to a mirror shine\u2026',
      'Folding the map along its mirror lines\u2026',
      'Squats. Even robots warm up\u2026',
      'Chalking the grid\u2026',
      'Scouting the dark corners\u2026',
      'Reviewing the game plan\u2026'"""),
    ("the four cogs prepping their paintball markers", "the four commanders reading their maps"),
    (">In the locker room<", ">Four crowns, one map<"),
    ("Replay hash mismatch \u2014 showing recorded inputs",
     "Replay hash mismatch \u2014 showing recorded plans"),
    ("Spoilers: kills / flag story / winner on the timeline ahead of the playhead (o)",
     "Spoilers: cities / crowns found / crowns taken / winner on the timeline (o)"),
    ("window.CtfStaticReplay", "window.GenStaticReplay"),
    ("'ctf-shell'", "'gen-shell'"),
    ("window.PaintballChrome", "window.GenGeneralsChrome"),
    ("PAINTBALL additions run last", "GEN-GENERALS-IO additions run last"),
    ("var PB_MODE = false;", "var GEN_MODE = true;"),
    ("PB_MODE", "GEN_MODE"),
    ("PB_CTX", "GEN_CTX"),
    ("mirrors the squad-pip lens, but", "mirrors the fog lens, but"),
    ("the same v: command a squad-pip click sends", "the same v: command the chrome sends"),
]
for old, new in REPLACEMENTS:
    text = text.replace(old, new)

out_path.write_text(text, encoding="utf-8")
print("wrote", out_path, len(text), "bytes")
