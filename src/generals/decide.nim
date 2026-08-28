## The decision layer: one PARALLEL batch of LLM calls per directive turn,
## two bounded whole-second deadlines, the `turnSpacingMs` rate floor, the
## rolling rate guard, the budget guard, tolerant parsing, rune caps and the
## scripted fallback beneath all of it.
##
## Forked from coworld-ctf's `src/ctf/decide.nim`. This is a
## SIMULTANEOUS-decision game, so every living seat's request goes out in ONE
## `curly.makeRequests` batch: seats are never queried sequentially, which is
## what keeps 30 directive turns inside the wall-clock budget.

import std/[json, monotimes, os, strutils, times]
import curly
import sim_types, sim_config, sim_state, sim as gensim, llm

type
  BatchRequest* = object
    seat*: int
    url*: string
    headers*: HttpHeaders
    body*: string

  BatchReply* = object
    seat*: int
    text*: string
    error*: string
    code*: int

  BatchRunner* = proc (requests: seq[BatchRequest],
    deadlineSeconds: int): seq[BatchReply] {.closure.}
    ## The whole batch, issued at once. Tests substitute a fake that records
    ## each call's in-flight window and assert all four intersect.

  SeatPolicy* = object
    isLlm*: bool
    prompt*: string
    baseline*: ScriptKind
    connected*: bool

  DecideEngine* = ref object
    client*: LlmClient
    runner*: BatchRunner
    seats*: array[Seats, SeatPolicy]
    llmOff*: bool
    budgetGuardTurn*: int
    batchStarted*: bool
    lastBatchStart*: MonoTime
    requestStamps*: seq[MonoTime]
    fallbacks*: seq[JsonNode]
    lastLand*: array[Seats, int]
    lastArmy*: array[Seats, int]
    lastCities*: array[Seats, int]
    sleepBetweenBatches*: bool

const RollingRequestCap* = 28

proc defaultRunner*(client: LlmClient): BatchRunner =
  ## The real transport. `curly.makeRequests` issues the whole batch in
  ## parallel and returns when the slowest reply lands or the deadline does.
  result = proc (requests: seq[BatchRequest],
      deadlineSeconds: int): seq[BatchReply] {.closure.} =
    var batch: RequestBatch
    for request in requests:
      batch.post(request.url, request.headers, request.body, $request.seat)
    let responses = client.curl.makeRequests(batch, max(1, deadlineSeconds))
    for position, request in requests:
      var reply = BatchReply(seat: request.seat)
      try:
        reply.text = client.textOf(responses[position].response,
          responses[position].error, request.url)
        reply.code = responses[position].response.code
      except CatchableError as error:
        reply.error = error.msg
        if responses[position].error.len > 0:
          reply.error = responses[position].error
        elif error.msg.startsWith("llm throttled"):
          reply.error = error.msg
      result.add(reply)

proc newDecideEngine*(client: LlmClient, runner: BatchRunner = nil):
    DecideEngine =
  result = DecideEngine(client: client, budgetGuardTurn: -1,
    sleepBetweenBatches: true)
  result.runner = if runner != nil: runner else: defaultRunner(client)

proc setSeatPolicy*(engine: DecideEngine, seat: int, isLlm: bool,
    prompt: string, baseline: ScriptKind, connected = true) =
  engine.seats[seat] = SeatPolicy(isLlm: isLlm, prompt: prompt,
    baseline: baseline, connected: connected)

proc causeOf(error: string): FallbackCause =
  let lower = error.toLowerAscii()
  if "timeout" in lower or "timed out" in lower: fcTimeout
  elif "throttled" in lower: fcThrottled
  elif "transport" in lower or "could not resolve" in lower or
      "connection" in lower: fcTransport
  else: fcParse

proc fallbackRecord*(turn, seat, attempt: int, cause: FallbackCause,
    detail: string): JsonNode =
  %*{"turn": turn, "seat": seat, "attempt": attempt,
     "cause": $cause,
     "detail": truncateRunes(detail, MaxFallbackDetailRunes)}

proc rollingRequests*(engine: DecideEngine, now: MonoTime): int =
  for stamp in engine.requestStamps:
    if (now - stamp).inMilliseconds < 60_000:
      result.inc

proc noteRequests*(engine: DecideEngine, now: MonoTime, count: int) =
  for i in 0 ..< count:
    engine.requestStamps.add(now)
  var kept: seq[MonoTime] = @[]
  for stamp in engine.requestStamps:
    if (now - stamp).inMilliseconds < 120_000:
      kept.add(stamp)
  engine.requestStamps = kept

proc scriptedDecision*(sim: Sim, seat: int, kind: ScriptKind): Decision =
  let view = sim.viewOf(seat)
  Decision(plan: scriptedPlan(view, kind), source: psScripted)

proc fallbackDecision*(sim: Sim, seat: int, cause: FallbackCause,
    detail: string, attempts: int): Decision =
  ## The fallback plan is computed by the SAME proc the `sprawl` baseline
  ## uses - imported, never duplicated, so the two cannot drift.
  let view = sim.viewOf(seat)
  Decision(plan: fallbackPlan(view), source: psFallback, cause: cause,
    detail: truncateRunes(detail, MaxFallbackDetailRunes), attempts: attempts)

proc elapsedSeconds*(started: MonoTime): int =
  int((getMonoTime() - started).inMilliseconds div 1000)

proc decideTurn*(engine: DecideEngine, sim: var Sim, seats: seq[int],
    elapsedS: int): seq[Decision] =
  ## One directive turn. Returns one Decision per entry of `seats`, in that
  ## order. Every wait inside is bounded.
  var decisions: seq[Decision] = @[]
  var open: seq[int] = @[]
  for seat in seats:
    if engine.seats[seat].isLlm and engine.seats[seat].connected and
        not engine.llmOff and not engine.client.disabled:
      open.add(seat)
      decisions.add(Decision(source: psFallback))
    elif engine.seats[seat].isLlm:
      ## An LLM seat that CANNOT call the LLM this turn is a FALLBACK, not a
      ## scripted policy, and the cause names why.
      let cause =
        if engine.llmOff: fcBudgetGuard
        elif not engine.seats[seat].connected: fcDisconnected
        else: fcNoCreds
      decisions.add(fallbackDecision(sim, seat, cause,
        "the LLM is unavailable for this turn; playing sprawl", 1))
      engine.fallbacks.add(fallbackRecord(sim.turn, seat, 1, cause,
        "the LLM is unavailable for this turn; playing sprawl"))
      echo "gen-generals-io llm: seat ", seat, " falling back to sprawl (",
        cause, ") on turn ", sim.turn
    else:
      decisions.add(scriptedDecision(sim, seat, engine.seats[seat].baseline))

  ## The rate floor. The Bedrock sidecar caps 30 requests/minute per episode;
  ## holding the START of consecutive batches `turnSpacingMs` apart pins four
  ## seats at 4 x 60/9 = 26.7 req/min.
  if open.len > 0 and engine.batchStarted and sim.config.turnSpacingMs > 0 and
      engine.sleepBetweenBatches:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))

  ## The rolling rate guard: a turn in which every seat retries issues eight
  ## requests, so cap the trailing 60 s at 28 and let the seats that would
  ## exceed it take the sprawl plan for this turn.
  if open.len > 0:
    let now = getMonoTime()
    let inFlight = engine.rollingRequests(now)
    if inFlight + open.len * 2 > RollingRequestCap:
      var allowed: seq[int] = @[]
      for index, seat in open:
        if inFlight + (index + 1) * 2 <= RollingRequestCap:
          allowed.add(seat)
        else:
          let position = seats.find(seat)
          if position >= 0:
            decisions[position] = fallbackDecision(sim, seat, fcRateGuard,
              "rolling 60 s request cap reached", 1)
          engine.fallbacks.add(fallbackRecord(sim.turn, seat, 1, fcRateGuard,
            "rolling 60 s request cap reached"))
      open = allowed

  if open.len == 0:
    return decisions

  engine.lastBatchStart = getMonoTime()
  engine.batchStarted = true
  let turnStart = getMonoTime()
  let budgetMs = sim.config.turnBudgetMs

  var attempt = 0
  while open.len > 0 and attempt < 2:
    if engine.client.disabled:
      break
    if (getMonoTime() - turnStart).inMilliseconds.int >= budgetMs:
      for seat in open:
        let position = seats.find(seat)
        if position >= 0:
          decisions[position] = fallbackDecision(sim, seat, fcTimeout,
            "per-turn budget exhausted before attempt " & $(attempt + 1),
            attempt + 1)
        engine.fallbacks.add(fallbackRecord(sim.turn, seat, attempt + 1,
          fcTimeout, "per-turn budget exhausted"))
      open = @[]
      break
    let deadlineMs =
      if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs

    var requests: seq[BatchRequest] = @[]
    for seat in open:
      let view = sim.viewOf(seat)
      let observation = buildObservation(view, sim.config,
        sim.directiveIndex(), sim.directiveCount(), sim.plan[seat],
        sim.havePlan[seat],
        sim.howItWent(seat, engine.lastLand[seat], engine.lastArmy[seat],
          engine.lastCities[seat]))
      var user = userMessage(engine.seats[seat].prompt, $observation)
      if attempt > 0:
        user.add("\n\nYour previous reply was not usable. Reply with ONLY " &
          "the JSON object described above, starting with '{'.")
      let request = engine.client.requestFor(
        systemPromptFor(sim.config), user)
      requests.add(BatchRequest(seat: seat, url: request.url,
        headers: request.headers, body: request.body))

    engine.noteRequests(getMonoTime(), requests.len)
    let started = getMonoTime()
    ## ONE parallel batch. curly hands the deadline to CURLOPT_TIMEOUT, whose
    ## granularity is WHOLE SECONDS, so this division is an identity:
    ## sim_config rejects anything that is not a whole number of seconds.
    let replies = engine.runner(requests, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int

    var stillOpen: seq[int] = @[]
    for reply in replies:
      let seat = reply.seat
      let position = seats.find(seat)
      if position < 0:
        continue
      if reply.error.len > 0:
        let cause = causeOf(reply.error)
        engine.fallbacks.add(fallbackRecord(sim.turn, seat, attempt + 1,
          cause, reply.error))
        echo "gen-generals-io llm: seat ", seat, " attempt ", attempt + 1,
          " failed (", cause, "): ", truncateRunes(reply.error, 160)
        if attempt == 0 and not engine.client.throttled:
          stillOpen.add(seat)
        else:
          decisions[position] = fallbackDecision(sim, seat, cause,
            reply.error, attempt + 1)
        continue
      var repaired = 0
      let (plan, ok) = parsePlan(reply.text, sim.plan[seat],
        sim.havePlan[seat], repaired)
      if not ok:
        engine.fallbacks.add(fallbackRecord(sim.turn, seat, attempt + 1,
          fcParse, "no JSON object in the reply"))
        if attempt == 0:
          stillOpen.add(seat)
        else:
          decisions[position] = fallbackDecision(sim, seat, fcParse,
            "no JSON object in the reply", attempt + 1)
        continue
      sim.stats[seat].directivesRejected += repaired
      decisions[position] = Decision(plan: plan, source: psLlm,
        latencyMs: latency, attempts: attempt + 1)
    open = stillOpen
    attempt.inc
    if engine.client.throttled and open.len > 0:
      ## FAIL FAST: the only model left answered 429, so the retry batch
      ## would be refused the same way.
      for seat in open:
        let position = seats.find(seat)
        if position >= 0:
          decisions[position] = fallbackDecision(sim, seat, fcThrottled,
            "provider throttled and no candidate model is left", attempt)
        engine.fallbacks.add(fallbackRecord(sim.turn, seat, attempt,
          fcThrottled, "provider throttled; no candidate model left"))
      open = @[]
  engine.client.throttled = false
  discard elapsedS
  decisions

proc considerBudgetGuard*(engine: DecideEngine, sim: var Sim,
    elapsedS: int): bool =
  ## Settle early rather than overrun: with less than two full directive
  ## turns of reserve left, switch the LLM off for EVERY remaining directive
  ## turn so the episode ends `complete` rather than `deadline`.
  if engine.llmOff:
    return false
  let reserve = 2 * ((sim.config.turnSpacingMs + sim.config.turnBudgetMs) div 1000)
  if elapsedS + reserve > sim.config.wallClockBudgetSeconds:
    engine.llmOff = true
    engine.budgetGuardTurn = sim.turn
    return true
  false

proc noteTurnBaseline*(engine: DecideEngine, sim: Sim) =
  for seat in 0 ..< Seats:
    engine.lastLand[seat] = sim.stats[seat].land
    engine.lastArmy[seat] = int(sim.stats[seat].army)
    engine.lastCities[seat] = sim.stats[seat].cities
