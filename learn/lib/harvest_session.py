#!/usr/bin/env python3
"""Extract the small useful fraction out of pi's session .jsonl files.

Why this exists: session files have a terrible value density -- tens of KB each,
four fifths of it raw toolResult output. That is exactly what the "do not read
.jsonl directly" rule in AGENTS.md is about. Pasting a whole file into another
model just repeats the $0.18 mistake.

So this runs on the other machine and emits only two things:
  --mode skeleton   one line per turn: who spoke, how long, which tools, what it
                    cost. No content.
  --mode probes     only the turns where the assistant's reply contains a code
                    fence, carried out together with the user message that
                    triggered it -- these are the candidate violations of rule 1.

Usage (on the other machine):
    python3 harvest_session.py --days 7 --mode skeleton
    python3 harvest_session.py --days 7 --mode probes > probes.jsonl
"""
import argparse, json, re, sys
from datetime import date, timedelta
from pathlib import Path

SECRET = re.compile(r"(?i)(token|secret|key|password|authorization)\W{0,3}([A-Za-z0-9_\-\.]{16,})")
SNOWFLAKE = re.compile(r"\b\d{17,20}\b")


def scrub(s):
    s = SECRET.sub(r"\1=<redacted>", s)
    return SNOWFLAKE.sub("<discord-id>", s)


def text_of(parts):
    if isinstance(parts, str):
        return parts
    if not isinstance(parts, list):
        return ""
    return "".join(p.get("text", "") for p in parts if isinstance(p, dict) and p.get("type") == "text")


def tools_of(parts):
    if not isinstance(parts, list):
        return []
    return [p.get("name") for p in parts if isinstance(p, dict) and p.get("type") == "toolCall"]


def turns(path):
    """Flatten one session file into a sequence of (idx, role, text, tools, usage)."""
    meta = {"file": path.name, "cwd": None, "model": None}
    out = []
    for i, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines()):
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if rec.get("type") == "session":
            meta["cwd"] = rec.get("cwd")
        if rec.get("modelId"):
            meta["model"] = f'{rec.get("provider")}/{rec.get("modelId")}'
        msg = rec.get("message") or {}
        if not msg:
            continue
        parts = msg.get("content")
        out.append({
            "i": i,
            "role": msg.get("role"),
            "text": text_of(parts),
            "tools": tools_of(parts),
            "usage": msg.get("usage") or {},
        })
    return meta, out


def sessions(root, days, match):
    cutoff = date.today() - timedelta(days=days) if days else None
    for p in sorted(root.rglob("*.jsonl")):
        if match and match not in str(p.parent.name):
            continue
        try:
            day = date.fromisoformat(p.name[:10])
        except ValueError:
            day = date.fromtimestamp(p.stat().st_mtime)
        if cutoff and day < cutoff:
            continue
        yield p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sessions", default=str(Path.home() / ".pi/agent/sessions"))
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--match", default="Leetcode", help="only sessions whose cwd directory name contains this string")
    ap.add_argument("--mode", choices=["skeleton", "probes"], default="skeleton")
    ap.add_argument("--max-chars", type=int, default=1500, help="in probes mode, truncate each passage to this many characters")
    a = ap.parse_args()

    root = Path(a.sessions)
    if not root.is_dir():
        sys.exit(f"session directory not found: {root}")

    n = 0
    for path in sessions(root, a.days, a.match):
        meta, ts = turns(path)
        if not ts:
            continue
        n += 1
        if a.mode == "skeleton":
            cost = sum((t["usage"].get("cost") or {}).get("total", 0) or 0 for t in ts)
            print(f'\n■ {meta["file"]}  model={meta["model"]}  turns={len(ts)}  cost=${cost:.4f}')
            for t in ts:
                u = t["usage"]
                cst = (u.get("cost") or {}).get("total")
                fence = "```" in t["text"]
                print(f'  {t["i"]:3d} {t["role"]:10s} chars={len(t["text"]):6d}'
                      f' tools={",".join(filter(None, t["tools"])) or "-":20s}'
                      f' in={u.get("input","-"):>7} out={u.get("output","-"):>6}'
                      f' cost={cst if cst is None else round(cst,5)}'
                      f' {"⟨fence⟩" if fence else ""}')
        else:
            last_user = ""
            for t in ts:
                if t["role"] == "user":
                    last_user = t["text"]
                elif t["role"] == "assistant" and "```" in t["text"]:
                    print(json.dumps({
                        "file": meta["file"], "turn": t["i"], "model": meta["model"],
                        "user": scrub(last_user)[:a.max_chars],
                        "assistant": scrub(t["text"])[:a.max_chars],
                    }, ensure_ascii=False))
    print(f"\n(scanned {n} sessions)", file=sys.stderr)


if __name__ == "__main__":
    main()
