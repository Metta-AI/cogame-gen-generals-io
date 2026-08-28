# Build Docker. ONE image, TWO entrypoints: /bin/gen-generals-io (the game
# server, which also makes every LLM call) and /bin/gen-generals-io-player
# (the thin seat registrar). The policy set is env-switched inside this same
# image (PLAYER_PROMPT vs PLAYER_SCRIPTED), which is what keeps a champion and
# a scripted filler byte-identical apart from their environment.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/generals
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
RUN nim c \
  $NimFlags \
  --nimcache:/tmp/gen-generals-io-nimcache \
  --out:gen-generals-io \
  src/gen_generals_io.nim && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/gen-generals-io-player-nimcache \
  --out:gen-generals-io-player \
  src/gen_generals_io_player.nim

# Run Docker.
FROM --platform=linux/amd64 debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/generals
COPY --from=build /workspace/generals/gen-generals-io /bin/gen-generals-io
COPY --from=build /workspace/generals/gen-generals-io-player /bin/gen-generals-io-player
COPY --from=build /workspace/generals/*.json ./
COPY --from=build /workspace/generals/data ./data
COPY --from=build /workspace/generals/client ./client

CMD ["/bin/gen-generals-io"]
