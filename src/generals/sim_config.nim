## GameConfig lifecycle: defaults, the runtime JSON overlay, `validate` and
## the fully resolved config document pinned verbatim into every replay.
##
## Forked from coworld-ctf's `src/ctf/sim_config.nim`, keeping the two checks
## that matter for an LLM turn: the whole-second deadline rule (curl's
## CURLOPT_TIMEOUT is second-grained) and `attempt1Ms + retryMs <=
## turnBudgetMs`.

import std/[json, strutils]
import sim_types

type
  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    numAgents*: int
    minPlayers*: int
    teams*: int
    cogsPerTeam*: int
    boardW*, boardH*: int
    mountainPct*: int
    cityCount*: int
    cityArmy*: int
    maxTurns*: int
    growthPeriod*: int
    directiveEvery*: int
    scoutArmy*: int
    missionMaxSteps*: int
    defendTurns*: int
    attempt1Ms*: int
    retryMs*: int
    turnBudgetMs*: int
    turnSpacingMs*: int
    wallClockBudgetSeconds*: int
    episodeTimeoutSeconds*: int
    lobbyJoinTimeoutTicks*: int
    startWaitTicks*: int
    gameOverTicks*: int
    fastMode*: bool
    showPlayerLabels*: bool
    fullyObservable*: bool
    model*: string
    maxOutputTokens*: int

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    tokens: @[],
    players: @[],
    seed: 1734029581,
    numAgents: Seats,
    minPlayers: Seats,
    teams: Seats,
    cogsPerTeam: 1,
    boardW: 16,
    boardH: 10,
    mountainPct: 22,
    cityCount: 8,
    cityArmy: 40,
    maxTurns: 240,
    growthPeriod: 25,
    directiveEvery: 8,
    scoutArmy: 8,
    missionMaxSteps: 12,
    defendTurns: 6,
    attempt1Ms: 7000,
    retryMs: 3000,
    turnBudgetMs: 11000,
    turnSpacingMs: 9000,
    wallClockBudgetSeconds: 660,
    episodeTimeoutSeconds: 1200,
    lobbyJoinTimeoutTicks: 2400,
    startWaitTicks: 48,
    gameOverTicks: 72,
    fastMode: true,
    showPlayerLabels: false,
    fullyObservable: false,
    model: "",
    maxOutputTokens: 700
  )

proc wholeSeconds*(ms: int): bool {.inline.} =
  ms > 0 and ms mod 1000 == 0

proc validate*(config: GameConfig) =
  if config.numAgents != Seats:
    raise newException(GenError,
      "num_agents must be " & $Seats & ", got " & $config.numAgents)
  if config.boardW < 6 or config.boardW > BoardWMax or
      config.boardH < 6 or config.boardH > BoardHMax:
    raise newException(GenError, "board must be between 6x6 and 32x32")
  if config.boardW mod 2 != 0 or config.boardH mod 2 != 0:
    raise newException(GenError,
      "boardW and boardH must be even: the board is four-fold symmetric")
  if config.mountainPct < 0 or config.mountainPct > 60:
    raise newException(GenError, "mountainPct must be in 0..60")
  if config.cityCount < 0 or config.cityCount mod 4 != 0:
    raise newException(GenError, "cityCount must be a non-negative multiple of 4")
  if config.cityArmy < 1:
    raise newException(GenError, "cityArmy must be positive")
  if config.maxTurns < 1:
    raise newException(GenError, "maxTurns must be positive")
  if config.growthPeriod < 1:
    raise newException(GenError, "growthPeriod must be positive")
  if config.directiveEvery < 1:
    raise newException(GenError, "directiveEvery must be positive")
  if config.scoutArmy < 1:
    raise newException(GenError, "scoutArmy must be positive")
  if config.missionMaxSteps < 1:
    raise newException(GenError, "missionMaxSteps must be positive")
  ## curl's CURLOPT_TIMEOUT is whole seconds, so a fractional deadline is a
  ## deadline nobody honours. Reject it rather than silently round.
  if not wholeSeconds(config.attempt1Ms):
    raise newException(GenError,
      "attempt1Ms must be a positive whole number of seconds, got " &
        $config.attempt1Ms & " ms")
  if not wholeSeconds(config.retryMs):
    raise newException(GenError,
      "retryMs must be a positive whole number of seconds, got " &
        $config.retryMs & " ms")
  if config.attempt1Ms + config.retryMs > config.turnBudgetMs:
    raise newException(GenError,
      "attempt1Ms + retryMs must be <= turnBudgetMs (" &
        $config.attempt1Ms & " + " & $config.retryMs & " > " &
        $config.turnBudgetMs & ")")
  if config.turnSpacingMs < 0:
    raise newException(GenError, "turnSpacingMs must not be negative")
  if config.wallClockBudgetSeconds < 1:
    raise newException(GenError, "wallClockBudgetSeconds must be positive")
  ## Degrade-never-hang: play inside 60 % of the platform's episode timeout.
  if config.wallClockBudgetSeconds * 10 > config.episodeTimeoutSeconds * 6:
    raise newException(GenError,
      "wallClockBudgetSeconds must be inside 60% of episodeTimeoutSeconds (" &
        $config.wallClockBudgetSeconds & " > " &
        $(config.episodeTimeoutSeconds * 6 div 10) & ")")

proc update*(config: var GameConfig, configJson: string) =
  ## Applies the runtime JSON config on top of the defaults, then validates.
  if configJson.strip().len == 0:
    config.validate()
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(GenError, "config must be a JSON object")

  template intField(key: string, target: untyped) =
    if node.hasKey(key):
      target = node[key].getInt()
  template boolField(key: string, target: untyped) =
    if node.hasKey(key):
      target = node[key].getBool()

  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player{"name"}.getStr()))
  intField("seed", config.seed)
  intField("num_agents", config.numAgents)
  intField("minPlayers", config.minPlayers)
  intField("teams", config.teams)
  intField("cogsPerTeam", config.cogsPerTeam)
  intField("boardW", config.boardW)
  intField("boardH", config.boardH)
  intField("mountainPct", config.mountainPct)
  intField("cityCount", config.cityCount)
  intField("cityArmy", config.cityArmy)
  intField("maxTurns", config.maxTurns)
  intField("growthPeriod", config.growthPeriod)
  intField("directiveEvery", config.directiveEvery)
  intField("scoutArmy", config.scoutArmy)
  intField("missionMaxSteps", config.missionMaxSteps)
  intField("defendTurns", config.defendTurns)
  intField("attempt1Ms", config.attempt1Ms)
  intField("retryMs", config.retryMs)
  intField("turnBudgetMs", config.turnBudgetMs)
  intField("turnSpacingMs", config.turnSpacingMs)
  intField("wallClockBudgetSeconds", config.wallClockBudgetSeconds)
  intField("episodeTimeoutSeconds", config.episodeTimeoutSeconds)
  intField("lobbyJoinTimeoutTicks", config.lobbyJoinTimeoutTicks)
  intField("startWaitTicks", config.startWaitTicks)
  intField("gameOverTicks", config.gameOverTicks)
  intField("maxOutputTokens", config.maxOutputTokens)
  boolField("fastMode", config.fastMode)
  boolField("showPlayerLabels", config.showPlayerLabels)
  boolField("fullyObservable", config.fullyObservable)
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  config.validate()

proc configJson*(config: GameConfig): JsonNode =
  ## The fully resolved config, TOKENS EXCLUDED, pinned into the replay.
  var players = newJArray()
  for player in config.players:
    players.add(%*{"name": player.name})
  %*{
    "seed": config.seed,
    "num_agents": config.numAgents,
    "minPlayers": config.minPlayers,
    "teams": config.teams,
    "cogsPerTeam": config.cogsPerTeam,
    "boardW": config.boardW,
    "boardH": config.boardH,
    "mountainPct": config.mountainPct,
    "cityCount": config.cityCount,
    "cityArmy": config.cityArmy,
    "maxTurns": config.maxTurns,
    "growthPeriod": config.growthPeriod,
    "directiveEvery": config.directiveEvery,
    "scoutArmy": config.scoutArmy,
    "missionMaxSteps": config.missionMaxSteps,
    "defendTurns": config.defendTurns,
    "attempt1Ms": config.attempt1Ms,
    "retryMs": config.retryMs,
    "turnBudgetMs": config.turnBudgetMs,
    "turnSpacingMs": config.turnSpacingMs,
    "wallClockBudgetSeconds": config.wallClockBudgetSeconds,
    "episodeTimeoutSeconds": config.episodeTimeoutSeconds,
    "lobbyJoinTimeoutTicks": config.lobbyJoinTimeoutTicks,
    "startWaitTicks": config.startWaitTicks,
    "gameOverTicks": config.gameOverTicks,
    "fastMode": config.fastMode,
    "showPlayerLabels": config.showPlayerLabels,
    "fullyObservable": config.fullyObservable,
    "maxOutputTokens": config.maxOutputTokens,
    "players": players
  }

proc configFromJson*(node: JsonNode): GameConfig =
  ## Rebuilds a config from a replay's pinned config document.
  result = defaultGameConfig()
  result.update($node)
