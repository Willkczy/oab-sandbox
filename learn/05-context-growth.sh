#!/bin/sh
# 實驗：LLM 沒有記憶，每一輪都把整段歷史重送一次。
#
# 測什麼   : 真實對話裡 input token 與 output token 的走勢差異
# 預期看到 : input 單調遞增（因為每次重送全部），output 沒有趨勢
# 資料來源 : ~/.pi/agent/sessions/ 的實際紀錄（只讀 usage 欄位，不讀對話內容）
# 重跑     : ./learn/05-context-growth.sh [sessions 目錄]
#
# 想看別的 vault 的紀錄，就把目錄當參數傳進來。

set -e
cd "$(dirname "$0")/.."

# 不給參數時，自動挑 ~/.pi/agent/sessions/ 底下最近有活動的那個。
# （原本這裡寫死作者的 vault 路徑，別人 clone 下來會直接撲空。）
SESSIONS="${1:-$(ls -dt "$HOME"/.pi/agent/sessions/*/ 2>/dev/null | head -1)}"

echo "=== 每輪送進模型的 token 量 ==="
python3 learn/lib/token_growth.py "$SESSIONS"

echo
echo "=== 常駐成本：每一輪都要重付的固定開銷 ==="
for f in vault/AGENTS.md vault/教練規則/*.md; do
    chars=$(wc -m < "$f" | tr -d ' ')
    printf "  %-34s %6s 字元  ≈ %5s tokens\n" "${f#vault/}" "$chars" "$((chars * 2 / 3))"
done
echo "  （中文粗估 1 字 ≈ 0.67 token）"
