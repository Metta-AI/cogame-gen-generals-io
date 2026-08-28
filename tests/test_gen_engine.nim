## Test 17 — the directive loop against a FAKE LLM client.
##
## Nothing here opens a socket: the decision engine takes its transport as a
## `BatchRunner`, so a test can record every call's in-flight window and
## assert that all four seats' requests really were ONE parallel batch.

import std/[unittest, json, monotimes, os, strutils, times]
import generals/sim as gensim
import generals/llm
import generals/decide

type
  Window = object
    seat: int
    startMs, endMs: int

var windows: seq[Window]
var batches: int

proc freshSim(): Sim =
  var config = defaultGameConfig()
  config.turnSpacingMs = 0
  config.players = @[]
  for seat in 0 ..< Seats:
    config.players.add(PlayerConfig(name: "seat-" & $seat))
  gensim.initSim(config)

proc engineWith(runner: BatchRunner): DecideEngine =
  var client = LlmClient(transport: ltAnthropic, model: "test",
    maxOutputTokens: 700)
  result = newDecideEngine(client, runner)
  result.sleepBetweenBatches = false
  for seat in 0 ..< Seats:
    result.setSeatPolicy(seat, isLlm = true, prompt = "play well",
      baseline = skSprawl)

proc goodRunner(delayMs: int): BatchRunner =
  result = proc (requests: seq[BatchRequest],
      deadlineSeconds: int): seq[BatchReply] {.closure.} =
    batches.inc
    let started = getMonoTime()
    ## The whole batch is in flight at once, exactly as
    ## `curly.makeRequests` runs it.
    if delayMs > 0:
      sleep(delayMs)
    let ended = getMonoTime()
    for request in requests:
      windows.add(Window(seat: request.seat,
        startMs: int((started - MonoTime()).inMilliseconds),
        endMs: int((ended - MonoTime()).inMilliseconds)))
      result.add(BatchReply(seat: request.seat,
        text: "{\"intent\":\"raid\",\"scouts\":1,\"note\":\"hunting\"}"))

suite "the directive loop":
  setup:
    windows = @[]
    batches = 0

  test "all four seats go out in ONE parallel batch":
    var sim = freshSim()
    let engine = engineWith(goodRunner(20))
    let seats = sim.aliveSeats()
    let decisions = engine.decideTurn(sim, seats, 0)
    check decisions.len == Seats
    check batches == 1
    check windows.len == Seats
    ## Every seat's window intersects every other seat's.
    for a in windows:
      for b in windows:
        check a.startMs <= b.endMs
        check b.startMs <= a.endMs
    for decision in decisions:
      check decision.source == psLlm
      check decision.plan.intent == inRaid
      check decision.plan.note == "hunting"

  test "an eliminated seat is dropped from the next batch":
    var sim = freshSim()
    let engine = engineWith(goodRunner(0))
    discard engine.decideTurn(sim, sim.aliveSeats(), 0)
    check windows.len == Seats
    sim.stats[2].alive = false
    windows = @[]
    let decisions = engine.decideTurn(sim, sim.aliveSeats(), 0)
    check decisions.len == Seats - 1
    check windows.len == Seats - 1
    for window in windows:
      check window.seat != 2

  test "a hung client is bounded by the per-turn budget":
    var sim = freshSim()
    sim.config.attempt1Ms = 1000
    sim.config.retryMs = 1000
    sim.config.turnBudgetMs = 2000
    let runner = proc (requests: seq[BatchRequest],
        deadlineSeconds: int): seq[BatchReply] {.closure.} =
      ## A transport that answers only with its own deadline, the way curl
      ## does when CURLOPT_TIMEOUT fires.
      sleep(deadlineSeconds * 1000)
      for request in requests:
        result.add(BatchReply(seat: request.seat,
          error: "Timeout was reached"))
    let engine = engineWith(runner)
    let started = epochTime()
    let decisions = engine.decideTurn(sim, sim.aliveSeats(), 0)
    let elapsed = epochTime() - started
    check elapsed < 6.0
    for decision in decisions:
      check decision.source == psFallback
      check decision.cause == fcTimeout

  test "a timeout on attempt 1 buys exactly one retry":
    var sim = freshSim()
    var attempt = 0
    let runner = proc (requests: seq[BatchRequest],
        deadlineSeconds: int): seq[BatchReply] {.closure.} =
      attempt.inc
      for request in requests:
        if attempt == 1:
          result.add(BatchReply(seat: request.seat,
            error: "Timeout was reached"))
        else:
          result.add(BatchReply(seat: request.seat,
            text: "{\"intent\":\"gather\"}"))
    let engine = engineWith(runner)
    let decisions = engine.decideTurn(sim, sim.aliveSeats(), 0)
    check attempt == 2
    for decision in decisions:
      check decision.source == psLlm
      check decision.plan.intent == inGather

  test "two consecutive failures give the sprawl plan and a fallback record":
    var sim = freshSim()
    let runner = proc (requests: seq[BatchRequest],
        deadlineSeconds: int): seq[BatchReply] {.closure.} =
      for request in requests:
        result.add(BatchReply(seat: request.seat, text: "no json here"))
    let engine = engineWith(runner)
    let decisions = engine.decideTurn(sim, sim.aliveSeats(), 0)
    for index, seat in sim.aliveSeats():
      check decisions[index].source == psFallback
      check decisions[index].cause == fcParse
      check decisions[index].plan == sprawlPlan(sim.viewOf(seat))
    check engine.fallbacks.len == Seats * 2

  test "a throttled attempt 1 with no candidate left skips the retry":
    var sim = freshSim()
    var calls = 0
    var client = LlmClient(transport: ltAnthropic, model: "test",
      maxOutputTokens: 700)
    let runner = proc (requests: seq[BatchRequest],
        deadlineSeconds: int): seq[BatchReply] {.closure.} =
      calls.inc
      client.throttled = true
      for request in requests:
        result.add(BatchReply(seat: request.seat,
          error: "llm throttled (429): daily cap"))
    let engine = newDecideEngine(client, runner)
    engine.sleepBetweenBatches = false
    for seat in 0 ..< Seats:
      engine.setSeatPolicy(seat, true, "prompt", skSprawl)
    let decisions = engine.decideTurn(sim, sim.aliveSeats(), 0)
    check calls == 1
    for decision in decisions:
      check decision.source == psFallback
      check decision.cause == fcThrottled

  test "config.validate rejects sub-second and over-budget deadlines":
    var config = defaultGameConfig()
    config.attempt1Ms = 6500
    expect GenError:
      config.validate()
    config = defaultGameConfig()
    config.retryMs = 500
    expect GenError:
      config.validate()
    config = defaultGameConfig()
    config.attempt1Ms = 9000
    config.retryMs = 3000
    config.turnBudgetMs = 11000
    expect GenError:
      config.validate()
    config = defaultGameConfig()
    config.wallClockBudgetSeconds = 800
    expect GenError:
      config.validate()

  test "the rate floor holds four seats under 30 requests a minute":
    let config = defaultGameConfig()
    let perMinute = Seats * 60000 div config.turnSpacingMs
    check perMinute <= 30
    check config.attempt1Ms + config.retryMs <= config.turnBudgetMs

  test "the rolling guard caps an all-retry turn at 28 requests":
    var sim = freshSim()
    let engine = engineWith(goodRunner(0))
    ## Pretend 24 requests have already gone out inside the window.
    engine.noteRequests(getMonoTime(), 24)
    let decisions = engine.decideTurn(sim, sim.aliveSeats(), 0)
    var guarded = 0
    for decision in decisions:
      if decision.cause == fcRateGuard:
        guarded.inc
    check guarded > 0
    check engine.rollingRequests(getMonoTime()) <= RollingRequestCap

  test "the budget guard switches to scripted and the episode ends complete":
    var sim = freshSim()
    let engine = engineWith(goodRunner(0))
    check engine.considerBudgetGuard(sim, sim.config.wallClockBudgetSeconds)
    check engine.llmOff
    let decisions = engine.decideTurn(sim, sim.aliveSeats(), 0)
    for decision in decisions:
      check decision.source == psFallback
      check decision.cause == fcBudgetGuard
    ## The episode still runs to a complete ending on the scripted layer.
    while not sim.done:
      if sim.isDirectiveTurn():
        for seat in sim.aliveSeats():
          sim.installPlan(seat, sprawlPlan(sim.viewOf(seat)), psScripted, 0)
      sim.stepTurn()
    check sim.reason == "complete"

  test "a disconnected seat plays sprawl and revives on reconnect":
    var sim = freshSim()
    let engine = engineWith(goodRunner(0))
    engine.setSeatPolicy(1, isLlm = true, prompt = "p", baseline = skSprawl,
      connected = false)
    var decisions = engine.decideTurn(sim, sim.aliveSeats(), 0)
    check decisions[1].source == psFallback
    check decisions[1].cause == fcDisconnected
    check decisions[1].plan == sprawlPlan(sim.viewOf(1))
    engine.setSeatPolicy(1, isLlm = true, prompt = "p", baseline = skSprawl,
      connected = true)
    decisions = engine.decideTurn(sim, sim.aliveSeats(), 0)
    check decisions[1].source == psLlm

  test "a scripted seat consumes no request at all":
    var sim = freshSim()
    let engine = engineWith(goodRunner(0))
    engine.setSeatPolicy(3, isLlm = false, prompt = "", baseline = skCrown)
    let decisions = engine.decideTurn(sim, sim.aliveSeats(), 0)
    check windows.len == Seats - 1
    check decisions[3].source == psScripted
    check decisions[3].plan == crownPlan(sim.viewOf(3))

  test "no living seat is ever left without a move or a recorded pass":
    var sim = freshSim()
    let kinds = [skSprawl, skCrown, skSprawl, skCrown]
    while not sim.done:
      if sim.isDirectiveTurn():
        for seat in sim.aliveSeats():
          sim.installPlan(seat, scriptedPlan(sim.viewOf(seat), kinds[seat]),
            psScripted, 0)
      var before: array[Seats, int]
      for seat in 0 ..< Seats:
        before[seat] = int(sim.stats[seat].movesMade) + sim.stats[seat].passes +
          sim.stats[seat].invalidMoves
      let living = sim.aliveSeats()
      sim.stepTurn()
      for seat in living:
        let after = int(sim.stats[seat].movesMade) + sim.stats[seat].passes +
          sim.stats[seat].invalidMoves
        check after > before[seat]
