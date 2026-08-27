#!/usr/bin/env python3
"""從 pi 的 session .jsonl 榨出「值得帶回去的那一小撮」。

為什麼需要這支：session 檔的價值密度極低（一個檔十幾 KB，八成是 toolResult
的原始輸出）。AGENTS.md 那條「不要直接讀 .jsonl」的規則講的就是這件事。
把整個檔貼給另一個模型，等於把 $0.18 的錯誤再犯一次。

所以這支在**舊機上**跑，只輸出兩種東西：
  --mode skeleton   每輪一行：誰說話、多長、用了什麼工具、花多少。不含內容。
  --mode probes     只挑出「assistant 回應裡有 code fence」的那幾輪，
                    連同觸發它的 user 訊息一起帶出來 —— 這正是規則 1 的違規候選。

用法（在舊機）：
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
    """把一個 session 檔攤平成 (idx, role, text, tools, usage) 的序列。"""
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
    ap.add_argument("--match", default="Leetcode", help="只看 cwd 目錄名含這個字串的 session")
    ap.add_argument("--mode", choices=["skeleton", "probes"], default="skeleton")
    ap.add_argument("--max-chars", type=int, default=1500, help="probes 模式下每段文字的截斷長度")
    a = ap.parse_args()

    root = Path(a.sessions)
    if not root.is_dir():
        sys.exit(f"找不到 session 目錄：{root}")

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
    print(f"\n（掃了 {n} 個 session）", file=sys.stderr)


if __name__ == "__main__":
    main()
