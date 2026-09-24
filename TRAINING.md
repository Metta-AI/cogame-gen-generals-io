# GEN Generals.io post-training

`tools/export_posttrain.nim` plays ten complete native games per certified
variant. At each directive turn it captures the exact hosted system prompt
and fogged seat observation. The shipped sprawl and crown policies supply
plans accepted by the production parser. All living seats choose from the
same pre-turn state, then the native simulator advances. Whole games stay
in one data split.

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/gen-generals-posttrain tools/export_posttrain.nim
python3 tools/test_posttrain.py /tmp/gen-generals-posttrain
/tmp/gen-generals-posttrain /tmp/gen-generals-data 10 ffa
```

The other certified variants are `blitz` and `citadels`. Ten games yielded
735 train and 208 validation decisions for `ffa`, 460 and 134 for `blitz`,
and 735 and 225 for `citadels`. The largest examples used 2,733, 2,550,
and 2,724 tokens with a local Qwen2.5 tokenizer, all within 4,096 tokens.
One CPU optimizer step on a tiny local model reduced validation loss from
5.5952 to 5.5072, 5.4729 to 5.3898, and 5.4625 to 5.3688, respectively.
These short runs verify the training path, not policy quality.

From a Metta checkout with `metta-posttrain` installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/gen-generals-data --output /tmp/gen-generals-adapter \
  --model Qwen/Qwen3-0.6B --max-steps 100 --max-length 4096
```

The exporter preserves the native fog boundary: prompts contain only the
acting seat's visible and remembered cells.

## Numeric reinforcement learning

`tools/train_bridge.nim` exposes 834 values from the acting seat's fogged
view, public standings, and previous plan. Seven action heads choose intent,
optional target coordinates, reserve, city policy, and scouting rate. Four
living seats choose against the same pre-turn state, then the production
simulator executes the plans until the next directive turn.

```sh
nim c -d:release --path:src -o:/tmp/gen-generals-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/gen-generals-train-bridge
```

From a Metta checkout with the Coworld training stack, pass absolute bridge
and manifest paths to `recipes.external.coworld.train` for native PufferLib,
or `recipes.external.coworld_metta_rl.train` for Metta RL. Use `players=4`,
`max_decisions=160`, a timestep limit, and one of the three variant IDs.
The bridge also publishes the hosted observation as `semantic_view` and
`messages`.
