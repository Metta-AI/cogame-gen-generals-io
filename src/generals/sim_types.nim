## gen-generals-io core types, constants and the rune-safe string caps.
##
## Forked from coworld-ctf's `src/ctf/sim_types.nim`: the GameVersion
## changelog discipline, the rune caps, the four-team `Team` enum and
## `teamText`, and `TargetFps` / `ReplayFps` are the starter's. Everything
## about paint, guns, flags, hearts and hills is gone with the mechanics.
##
## Every value the deterministic step touches is an integer. A CI grep over
## board/vision/resolve/scoring/captain/baselines/sim refuses a floating point
## routine in the sim path.

import std/[strutils, unicode]

const
  GameVersion* = "1"
    ## GV1 (gen-generals-io v1): four crowns on a seeded four-fold-symmetric
    ## grid, fog by adjacency, crown capture inherits everything, +1 on every
    ## owned tile every `growthPeriod` turns. Prepend-only changelog: bump
    ## whenever a recorded plan would re-derive a different board.

  GameName* = "gen-generals-io"
  ReplayProtocol* = "gen-generals-io/v1"

  TargetFps* = 24
    ## The lobby runs at the starter's real-time rate.
  ReplayFps* = 12
    ## Playback rate: twelve turns a second. An `ffa` replay is
    ## 48 + 240 + 72 = 360 ticks => 30 s, comfortably past a 10 s soak.
  PlaybackSpeeds* = [1, 2, 4, 8]

  Seats* = 4
  BoardWMax* = 32
  BoardHMax* = 32

  ## Caps, in RUNES. Truncation is never on a byte boundary.
  MaxIntentRunes* = 10
  MaxCitiesRunes* = 8
  MaxNoteRunes* = 160
  MaxPolicyLabelRunes* = 48
  MaxFallbackDetailRunes* = 200
  MaxPromptRunes* = 4000
  MaxHowItWentRunes* = 240
  MaxReplyBytes* = 4096

  MaxCellArmy* = 100_000
  MaxArmiesReported* = 40
  MaxKnownCities* = 8
  MaxKnownGenerals* = 3
  MaxFrontier* = 8

  IdentityNames* = ["alpha", "bravo", "charlie", "delta"]

type
  GenError* = object of CatchableError
  GenGuardError* = object of GenError

  Team* = enum
    teamRed = "red"
    teamBlue = "blue"
    teamGreen = "green"
    teamYellow = "yellow"

  CellKind* = enum
    ckPlain = "plain"
    ckMountain = "mountain"
    ckCity = "city"
    ckGeneral = "general"

  Dir* = enum
    dirN = "N"
    dirE = "E"
    dirS = "S"
    dirW = "W"

  Move* = object
    fromCell*: int
    dir*: Dir
    amount*: int

  Intent* = enum
    inExpand = "expand"
    inGather = "gather"
    inAttack = "attack"
    inDefend = "defend"
    inScout = "scout"
    inRaid = "raid"

  CityPolicy* = enum
    cpNever = "never"
    cpCheap = "cheap"
    cpAlways = "always"

  Plan* = object
    ## The five structured fields the LLM decides plus the spectator note.
    ## Only the five fields are mixed into `gameHash`; the note is not.
    intent*: Intent
    hasTarget*: bool
    targetX*, targetY*: int
    reserve*: int
    cities*: CityPolicy
    scouts*: int
    note*: string

  PlanSource* = enum
    psScripted = "scripted"
    psLlm = "llm"
    psFallback = "fallback"

  FallbackCause* = enum
    fcNone = "none"
    fcTimeout = "timeout"
    fcParse = "parse_error"
    fcTransport = "transport_error"
    fcThrottled = "throttled"
    fcNoCreds = "no_credentials"
    fcRateGuard = "rate_guard"
    fcBudgetGuard = "budget_guard"
    fcDisconnected = "disconnected"

  Decision* = object
    plan*: Plan
    source*: PlanSource
    latencyMs*: int
    attempts*: int
    cause*: FallbackCause
    detail*: string
    repaired*: int

  ScriptKind* = enum
    skNone = "none"
    skSprawl = "sprawl"
    skCrown = "crown"

proc defaultPlanValue*(): Plan =
  Plan(intent: inExpand, hasTarget: false, targetX: 0, targetY: 0,
    reserve: 0, cities: cpCheap, scouts: 1, note: "")

proc teamText*(team: Team): string =
  $team

proc teamOfSeat*(seat: int): Team =
  Team(seat mod Seats)

proc cogAlias*(seat: int): string =
  ## The starter's alias rule, unmodified: `RED-alpha`, `BLUE-alpha`, … with
  ## `teams: 4`, `cogsPerTeam: 1`. In-game the seats are ONLY these strings.
  toUpperAscii(teamText(teamOfSeat(seat))) & "-" & IdentityNames[0]

proc shortAlias*(seat: int): string =
  ## The map-legend / feed abbreviation: RED / BLUE / GREEN / YELLOW.
  toUpperAscii(teamText(teamOfSeat(seat)))

proc cornerOfSeat*(seat: int): string =
  case seat
  of 0: "top-left"
  of 1: "top-right"
  of 2: "bottom-left"
  else: "bottom-right"

proc truncateRunes*(text: string, cap: int): string =
  ## Truncate on RUNE boundaries, never bytes. A byte-truncated multi-byte
  ## character renders in a browser and fails a strict parser, which is the
  ## bug this proc exists to make impossible.
  if cap <= 0:
    return ""
  if text.runeLen <= cap:
    return text
  text.runeSubStr(0, cap)

proc runeCap*(text: string, cap: int): string {.inline.} =
  truncateRunes(text, cap)

proc sanitizeNote*(text: string, cap = MaxNoteRunes): string =
  ## Collapse newlines and control characters to spaces, squeeze runs, then
  ## truncate on a rune boundary.
  var flat = newStringOfCap(text.len)
  var lastSpace = false
  for rune in text.runes:
    let value = int32(rune)
    if value < 32 or value == 127:
      if not lastSpace:
        flat.add(' ')
        lastSpace = true
    else:
      flat.add($rune)
      lastSpace = false
  truncateRunes(flat.strip(), cap)

proc parseIntentText*(text: string): (Intent, bool) =
  ## Tolerant: lower-cased, `-` and spaces folded to `_`.
  var normal = text.strip().toLowerAscii().multiReplace(
    ("-", "_"), (" ", "_"))
  normal = truncateRunes(normal, MaxIntentRunes)
  for value in Intent:
    if $value == normal:
      return (value, true)
  (inExpand, false)

proc parseCityPolicyText*(text: string): (CityPolicy, bool) =
  let normal = truncateRunes(
    text.strip().toLowerAscii(), MaxCitiesRunes)
  for value in CityPolicy:
    if $value == normal:
      return (value, true)
  (cpCheap, false)

proc parseScriptKind*(text: string): ScriptKind =
  ## Anything unrecognised is the published default (the starter's rule).
  case text.strip().toLowerAscii()
  of "sprawl": skSprawl
  of "crown": skCrown
  of "", "none": skNone
  else: skSprawl

proc dirDelta*(dir: Dir): (int, int) =
  case dir
  of dirN: (0, -1)
  of dirE: (1, 0)
  of dirS: (0, 1)
  of dirW: (-1, 0)
