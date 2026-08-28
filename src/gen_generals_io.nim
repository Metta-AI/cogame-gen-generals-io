## gen-generals-io entrypoint: reads the Coworld runtime contract and starts
## either a live episode server or a replay viewer server.
##
## Forked from coworld-ctf's `src/ctf.nim`, INCLUDING the rule that the seed
## is settled HERE, in the entrypoint, before anything derives from it: the
## injected `game_config` is applied first, and only a config that does NOT
## pin a seed is randomised — reading the pin is what the order is for. The
## board, this game's only seed-derived draw, is generated later, inside
## `runGameServer` -> `initSim`, so every draw follows the FINAL seed.

import std/[json, strutils, sysrand]
import bitworld/runtime
import generals/sim_types
import generals/sim_config
import generals/server

proc randomSeed(): int =
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(GenError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc seedPinned(configText: string): bool =
  if configText.strip().len == 0:
    return false
  try:
    let node = parseJson(configText)
    node.kind == JObject and node.hasKey("seed")
  except CatchableError:
    false

when isMainModule:
  var runtimeConfig: RuntimeConfig
  try:
    runtimeConfig = readRuntimeConfig()
  except CatchableError as error:
    quit("gen-generals-io: bad runtime configuration: " & error.msg, 2)

  if runtimeConfig.replayMode:
    runReplayServer(runtimeConfig)
  else:
    if runtimeConfig.config.strip().len == 0:
      quit("gen-generals-io: COGAME_CONFIG_URI is required", 2)
    var config = defaultGameConfig()
    try:
      config.update(runtimeConfig.config)
    except CatchableError as error:
      quit("gen-generals-io: invalid game config: " & error.msg, 2)
    if not seedPinned(runtimeConfig.config):
      config.seed = randomSeed()
      echo "gen-generals-io: seed not pinned; randomized to ", config.seed
    if config.tokens.len == 0:
      quit("gen-generals-io: the game config must carry one token per seat", 2)
    if config.players.len != config.numAgents:
      quit("gen-generals-io: the game config must name " &
        $config.numAgents & " players", 2)
    echo "gen-generals-io: seats=", config.numAgents,
      " board=", config.boardW, "x", config.boardH,
      " maxTurns=", config.maxTurns,
      " growthPeriod=", config.growthPeriod,
      " directiveEvery=", config.directiveEvery,
      " seed=", config.seed
    try:
      runGameServer(config, runtimeConfig)
    except CatchableError as error:
      quit("gen-generals-io: " & error.msg, 2)
