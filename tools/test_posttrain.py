"""Check complete, seed-separated GEN Generals.io post-training games."""

import json
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory


for variant in ("ffa", "blitz", "citadels"):
    with TemporaryDirectory() as temporary:
        output = Path(temporary) / variant
        subprocess.run([sys.argv[1], str(output), "10", variant], check=True)
        manifest = json.loads((output / "manifest.json").read_text())
        train = [json.loads(line) for line in (output / "train.jsonl").read_text().splitlines()]
        validation = [json.loads(line) for line in (output / "validation.jsonl").read_text().splitlines()]
        assert len(manifest["runs"]) == 10
        assert manifest["train_examples"] == len(train) > 0
        assert manifest["validation_examples"] == len(validation) > 0
        assert {row["seed"] for row in train}.isdisjoint({row["seed"] for row in validation})
        assert all(run["reason"] == "complete" for run in manifest["runs"])
        assert all(len(run["ranks"]) == 4 and all(0 <= rank <= 3 for rank in run["ranks"]) for run in manifest["runs"])
        for row in train + validation:
            assert row["game"] == "gen-generals-io"
            assert [part["role"] for part in row["prompt"]] == ["system", "user"]
            observation = json.loads(row["prompt"][1]["content"])
            assert {"terrain", "owner", "sight"} <= set(observation["board"])
            plan = json.loads(row["completion"][0]["content"])
            assert set(plan) == {"intent", "target", "reserve", "cities", "scouts", "note"}
            assert plan["intent"] in ("expand", "gather", "attack", "defend", "scout", "raid")
        print(f"{variant}: {len(train)} train, {len(validation)} validation decisions")
