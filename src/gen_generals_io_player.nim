## gen-generals-io player: a policy is just a prompt.
##
## Forked from coworld-ctf's `src/paintball_player.nim`. The container is
## deliberately thin: it connects, sends ONE Sprite v1 chat frame carrying
## its registration, and thereafter only receives. Every decision is made
## inside the GAME server, which sends this seat's prompt plus its fogged
## view to Claude once every eight turns, batched with the other seats.
##
##   PLAYER_PROMPT=<strategy text>   -> this seat is an LLM seat
##   PLAYER_SCRIPTED=sprawl|crown    -> this seat is a scripted baseline
##   (neither)                       -> sprawl, the published default
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <image> --name my-generals \
##     --run /bin/gen-generals-io-player --secret-env PLAYER_PROMPT="..."

import std/[json, options, os, strutils, times]
import whisky
import bitworld/spriteprotocol

const
  ConnectAttempts = 240
  ConnectBackoffMs = 500
  RedialAttempts = 6
  RegisterRepeats = 10
  RegisterSpacingMs = 1000.0
  ReceiveTimeoutMs = 5000
    ## No blocking read without a bound. whisky applies this timeout to the
    ## FRAME HEADER read only, so it fires when nothing has started arriving
    ## and can never cut a frame in half; it returns `none(Message)`.
  SilenceBudgetMs = 240_000.0
    ## How long total silence is allowed before this container leaves. The
    ## game pod always closes -- but a half-open TCP connection (a pod killed
    ## without a FIN) delivers no close frame and no error, and an unbounded
    ## `receiveMessage` would park here until the platform killed the pod.
    ## Comfortably above the longest legitimate quiet: the 100 s lobby join
    ## wait plus its registration grace.

when isMainModule:
  var url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    url = getEnv("COGAMES_ENGINE_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let prompt = getEnv("PLAYER_PROMPT")
  let scripted = getEnv("PLAYER_SCRIPTED").strip()
  let policy = getEnv("PLAYER_POLICY_LABEL")

  proc registrationText(): string =
    $ %*{
      "type": "register",
      "policy": policy,
      "prompt": prompt,
      "scripted": (if scripted.len > 0: %scripted else: newJNull())
    }

  proc dial(): WebSocket =
    for attempt in 1 .. ConnectAttempts:
      try:
        return newWebSocket(url)
      except CatchableError as error:
        if attempt mod 20 == 0:
          echo "gen-generals-io player: connect attempt ", attempt,
            " failed: ", error.msg
        if attempt == ConnectAttempts:
          ## Bounded, then leave quietly: the game declares the no-show
          ## itself and plays the seat on the sprawl baseline.
          echo "gen-generals-io player: giving up on ", url
          quit(0)
        sleep(ConnectBackoffMs)
    nil

  var socket = dial()
  if socket == nil:
    quit(0)

  proc sendRegistration(sock: WebSocket) =
    ## Sprite v1 chat frame (0x81). Registration is RE-SENT ten times over
    ## the first ten seconds because joins are slot-sequential: a seat whose
    ## slot is not the next open one is not admitted until the lower slot has
    ## joined (the paintball round-3 scar, where a champion played the
    ## baseline for a whole episode).
    try:
      sock.send(blobFromSpriteChat(registrationText()), BinaryMessage)
    except CatchableError as error:
      echo "gen-generals-io player: registration send failed: ", error.msg

  sendRegistration(socket)
  var registrationsSent = 1
  var lastRegistration = epochTime()
  echo "gen-generals-io player: registered (", prompt.len, " prompt chars",
    (if scripted.len > 0: ", scripted " & scripted else: ", llm"), ")"

  var redials = 0
  var running = true
  var lastTraffic = epochTime()
  while running:
    var received: Option[Message]
    try:
      received = socket.receiveMessage(ReceiveTimeoutMs)
    except CatchableError as error:
      ## whisky RAISES on a close frame or a truncated read, and mummy's
      ## `send` only queues: the game's `quit(0)` can outrun the flushed
      ## `done` frame. A naive player exits 1 here and fails certification
      ## intermittently (the raid 0.1.3 scar).
      echo "gen-generals-io player: connection ended (", error.msg, ")"
      redials.inc
      if redials > RedialAttempts:
        break
      try:
        socket.close()
      except CatchableError:
        discard
      var reconnected: WebSocket = nil
      try:
        reconnected = newWebSocket(url)
      except CatchableError:
        reconnected = nil
      if reconnected == nil:
        break
      socket = reconnected
      sendRegistration(socket)
      continue
    if received.isNone:
      ## An idle tick, not a close: whisky returns none ONLY on the header
      ## timeout (a close frame raises, and is handled above).
      if (epochTime() - lastTraffic) * 1000.0 >= SilenceBudgetMs:
        echo "gen-generals-io player: no traffic for ",
          int(SilenceBudgetMs / 1000.0), "s, exiting"
        break
      continue
    lastTraffic = epochTime()
    let message = received.get()
    ## The Ready packet (0x85) after each received frame is legitimate here
    ## because this seat never sends inputs: the server computes every move.
    try:
      socket.send(blobFromSpriteReady(), BinaryMessage)
    except CatchableError:
      discard
    if registrationsSent < RegisterRepeats and
        (epochTime() - lastRegistration) * 1000.0 >= RegisterSpacingMs:
      sendRegistration(socket)
      registrationsSent.inc
      lastRegistration = epochTime()
    if message.kind != TextMessage:
      continue
    try:
      let payload = parseJson(message.data)
      if payload{"done"}.getBool():
        echo "gen-generals-io player: final scores ",
          payload{"result"}{"scores"}
        running = false
        continue
      case payload{"type"}.getStr()
      of "welcome":
        echo "gen-generals-io player: seated at slot ",
          payload{"slot"}.getInt(), " as ", payload{"alias"}.getStr()
        sendRegistration(socket)
      of "turn":
        ## An ELIMINATED seat keeps receiving frames and exits 0 with
        ## everyone else: elimination is a game state, not a disconnection.
        discard
      else:
        discard
    except CatchableError as error:
      echo "gen-generals-io player: ignoring bad frame: ", error.msg
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
