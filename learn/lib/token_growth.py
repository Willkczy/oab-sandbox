#!/usr/bin/env python3
"""List token usage and cost for every model call in a single session.

The point: demonstrate that an LLM has no memory and resends the whole history
each turn -- input climbs monotonically, output does not. Only the usage fields
are read, never the conversation content.

Usage: python3 token_growth.py <sessions dir>
"""
import json
import sys
from pathlib import Path


def calls(path):
    """Every record in this .jsonl file that carries a usage field."""
    out = []
    for line in path.read_text(errors="replace").splitlines():
        if '"usage"' not in line:
            continue
        usage = json.loads(line).get("message", {}).get("usage")
        if usage:
            out.append(usage)
    return out


def main(root):
    files = list(Path(root).rglob("*.jsonl"))
    if not files:
        sys.exit(f"no session files found under {root}")

    # Pick the longest conversation; the growth trend only shows up there.
    target = max(files, key=lambda p: len(calls(p)))
    records = calls(target)

    print(f"session: {target.name[:19]} ({len(records)} model calls)\n")
    print(f"{'turn':>6} {'input sent':>14} {'output':>12} {'cost':>10} {'total':>9}")
    print("-" * 56)

    total = 0.0
    for i, u in enumerate(records, 1):
        # Add the cache-hit portions back into input -- they were sent too.
        sent = u["input"] + u.get("cacheRead", 0) + u.get("cacheWrite", 0)
        cost = u["cost"]["total"]
        total += cost
        print(f"{i:>6} {sent:>14,} {u['output']:>12,} {cost:>10.4f} {total:>9.4f}")

    print("-" * 56)
    first, last = records[0], records[-1]
    grew = (last["input"] + last.get("cacheRead", 0)) / (first["input"] + first.get("cacheRead", 0))
    print(f"input grew {grew:.1f}x   total cost of this conversation ${total:.4f}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else str(Path.home() / ".pi/agent/sessions"))
