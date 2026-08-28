import std/[os, strformat, strutils]

let rootDir = currentSourcePath().parentDir().parentDir()
let distDir = rootDir / "replay-viewer" / "dist"

if not dirExists(distDir):
  mkDir(distDir)

switch("path", rootDir / "src")
switch("nimcache", distDir / "nimcache")
switch("threads", "off")
--os:linux
--cpu:wasm32
--cc:clang
--clang.exe:emcc
--clang.linkerexe:emcc
--clang.cpp.exe:emcc
--clang.cpp.linkerexe:emcc
--mm:arc
--exceptions:goto
--define:noSignalHandler
--define:release
# Route every allocation through emscripten's malloc (the standard Nim
# emscripten setup). With Nim's bundled allocator a bad free silently poisons
# the freelists; dlmalloc traps loudly instead, which is how the
# use-after-free fixed in gen_replay.nim (emscripten_exit_with_live_runtime)
# was found. Keep this so any future stale free crashes at the fault instead
# of corrupting replay playback at a distance.
--define:useMalloc

# ENVIRONMENT includes worker because the shipped static bundle owns the WASM
# runtime in a Dedicated Worker, and node so CI can smoke-run that EXACT emitted
# module (tools/wasm_replay_smoke.cjs) — wasm32-only failures (int overflow traps,
# 2 GB address-space exhaustion) are invisible to the native 64-bit tests.
# ABORTING_MALLOC matters: with -d:useMalloc Nim never checks malloc for
# nil (that path is `when defined(zephyr)`-only), and wasm32 has no memory
# protection, so a failed allocation would otherwise write the seq header
# through the nil pointer into address 0 — silently corrupting the module's
# own globals, which is how oversized replays died with an EMPTY
# gen_error_len(). Aborting keeps linear memory intact, and the page reads
# gen_stage_ptr/len afterwards to report what the runtime was doing.
# The ONE line this file adds to the starter's (everything else in the diff
# against coworld-ctf's config.nims is an identifier rename): the wall
# textures the board's rig art blits -- client/art/walls/wall_{h,v}.jpg,
# loaded by src/generals/rig_art.nim -- live outside data/, and under
# emscripten a file that is not preloaded into MEMFS cannot be opened at all.
switch(
  "passL",
  (&"""
  -o {distDir / "gen_replay.js"}
  --preload-file {rootDir / "data"}@data
  --preload-file {rootDir / "client" / "art"}@art
  -O2
  -s ALLOW_MEMORY_GROWTH
  -s ABORTING_MALLOC=1
  -s FILESYSTEM=1
  -s ENVIRONMENT=web,worker,node
  -s EXPORTED_RUNTIME_METHODS=HEAPU8
  -s EXPORTED_FUNCTIONS=_main,_malloc,_free,_gen_load_replay,_gen_frame,_gen_input,_gen_packet_ptr,_gen_packet_len,_gen_mismatch_tick,_gen_error_ptr,_gen_error_len,_gen_stage_ptr,_gen_stage_len
  """).replace("\n", " ")
)
