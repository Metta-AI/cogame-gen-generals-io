#!/usr/bin/env python3
"""Print one strict-UTF-8 JSON object describing a COWLDGEN replay.

Python 3 stdlib only: no Nim, no Docker, no dependencies. This is the
forensic view of a binary replay -- the substitute for SPEC's "the replay
bytes must be valid UTF-8 JSON" check, which a binary format cannot satisfy
directly:

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null
    jq -r '.protocol, .results.reason, .results.land[]' /tmp/ep.json
    jq -r '[.plans[]|select(.source=="llm")]|length, .fallbacks' /tmp/ep.json
    jq -r '[.plans[]|select(.note!="")]|length' /tmp/ep.json

Everything it prints comes out of the bytes; no server is contacted.
"""
import json
import struct
import sys

MAGIC = b"COWLDGEN"
REC_JOIN, REC_PLAN, REC_CHAT, REC_HASH, REC_LEAVE = 1, 2, 3, 4, 5


class ReplayError(ValueError):
    pass


def _u16(data, offset):
    if offset + 2 > len(data):
        raise ReplayError("truncated replay")
    return struct.unpack_from(">H", data, offset)[0], offset + 2


def _u32(data, offset):
    if offset + 4 > len(data):
        raise ReplayError("truncated replay")
    return struct.unpack_from(">I", data, offset)[0], offset + 4


def parse(data: bytes) -> dict:
    if not data.startswith(MAGIC):
        raise ReplayError("not a COWLDGEN replay")
    offset = len(MAGIC)
    format_version, offset = _u16(data, offset)
    name_len, offset = _u16(data, offset)
    game_name = data[offset:offset + name_len].decode("utf-8")
    offset += name_len
    version_len, offset = _u16(data, offset)
    game_version = data[offset:offset + version_len].decode("utf-8")
    offset += version_len
    config_len, offset = _u32(data, offset)
    # Strict UTF-8, deliberately: a byte-truncated multi-byte character is
    # exactly the bug this check exists to catch.
    config = json.loads(data[offset:offset + config_len].decode("utf-8"))
    offset += config_len

    joins, plans, chats, hashes = [], [], [], []
    while offset < len(data):
        kind = data[offset]
        offset += 1
        length, offset = _u32(data, offset)
        payload = data[offset:offset + length]
        if len(payload) != length:
            raise ReplayError("truncated replay record")
        offset += length
        if kind == REC_HASH:
            turn, hashed = struct.unpack(">II", payload)
            hashes.append({"turn": turn, "hash": hashed})
            continue
        node = json.loads(payload.decode("utf-8"))
        if kind == REC_JOIN:
            joins.append(node)
        elif kind == REC_PLAN:
            plans.append(node)
        elif kind == REC_CHAT:
            chats.append(node)
        elif kind == REC_LEAVE:
            pass
        else:
            raise ReplayError("unknown record kind %d" % kind)

    registers = [c for c in chats if c.get("k") == "register"]
    plan_chats = [c for c in chats if c.get("k") == "plan"]
    fallbacks = [c for c in chats if c.get("k") == "fallback"]
    results = ([c for c in chats if c.get("k") == "result"] or [{}])[-1]
    results = {k: v for k, v in results.items() if k != "k"}

    seats = int(config.get("num_agents") or len(joins) or 4)
    names = [""] * seats
    for join in joins:
        slot = int(join.get("slot", -1))
        if 0 <= slot < seats:
            names[slot] = join.get("name", "")
    aliases = [""] * seats
    kinds = ["scripted"] * seats
    for record in registers:
        seat = int(record.get("seat", -1))
        if 0 <= seat < seats:
            aliases[seat] = record.get("alias", "")
            kinds[seat] = record.get("kind", "scripted")

    return {
        "protocol": "gen-generals-io/v1",
        "formatVersion": format_version,
        "gameName": game_name,
        "gameVersion": game_version,
        "seed": config.get("seed"),
        "boardW": config.get("boardW"),
        "boardH": config.get("boardH"),
        "names": names,
        "aliases": aliases,
        "policyKinds": kinds,
        "turnCount": max([h["turn"] for h in hashes], default=0),
        "hashCount": len(hashes),
        "plans": [
            {
                "turn": chat.get("turn"),
                "seat": chat.get("seat"),
                "alias": chat.get("alias", ""),
                "source": chat.get("source", ""),
                "intent": chat.get("intent", ""),
                "target": chat.get("target"),
                "reserve": chat.get("reserve"),
                "cities": chat.get("cities", ""),
                "scouts": chat.get("scouts"),
                "latency_ms": chat.get("latency_ms", 0),
                "note": chat.get("note", ""),
            }
            for chat in plan_chats
        ],
        "planInputs": len(plans),
        "fallbacks": len(fallbacks),
        "fallbackCauses": sorted({f.get("cause", "") for f in fallbacks}),
        "stop": ([c for c in chats if c.get("k") == "stop"] or [None])[-1],
        "budgetGuard": ([c for c in chats if c.get("k") == "budget_guard"] or [None])[-1],
        "config": config,
        "results": results,
    }


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: replay_summary.py <replay path>", file=sys.stderr)
        return 2
    with open(sys.argv[1], "rb") as handle:
        summary = parse(handle.read())
    sys.stdout.write(json.dumps(summary, ensure_ascii=False))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
