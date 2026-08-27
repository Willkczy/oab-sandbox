#!/usr/bin/env python3
"""列出單一 session 裡每一次模型呼叫的 token 用量與成本。

用途：證明「LLM 無記憶、每輪重送全部歷史」——input 會單調遞增，output 不會。
只讀 usage 欄位，不讀對話內容。

用法：python3 token_growth.py <sessions 目錄>
"""
import json
import sys
from pathlib import Path


def calls(path):
    """回傳這個 .jsonl 檔裡所有帶 usage 的紀錄。"""
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
        sys.exit(f"在 {root} 底下找不到 session 檔")

    # 挑對話最長的那一場，成長趨勢才看得出來
    target = max(files, key=lambda p: len(calls(p)))
    records = calls(target)

    print(f"session: {target.name[:19]}（共 {len(records)} 次模型呼叫）\n")
    print(f"{'第幾則':>6} {'送進去 input':>14} {'回應 output':>12} {'本則成本':>10} {'累計':>9}")
    print("-" * 56)

    total = 0.0
    for i, u in enumerate(records, 1):
        # input 要把 cache 命中的部分加回來，那些也是「送進去的內容」
        sent = u["input"] + u.get("cacheRead", 0) + u.get("cacheWrite", 0)
        cost = u["cost"]["total"]
        total += cost
        print(f"{i:>6} {sent:>14,} {u['output']:>12,} {cost:>10.4f} {total:>9.4f}")

    print("-" * 56)
    first, last = records[0], records[-1]
    grew = (last["input"] + last.get("cacheRead", 0)) / (first["input"] + first.get("cacheRead", 0))
    print(f"input 成長 {grew:.1f} 倍   這場對話總成本 ${total:.4f}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else str(Path.home() / ".pi/agent/sessions"))
