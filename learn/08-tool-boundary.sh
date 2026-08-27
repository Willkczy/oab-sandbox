#!/bin/sh
# 實驗：AGENTS.md 宣稱的寫入權限，跟 agent 實際握有的工具，差在哪？
#
# 測什麼   : pi 真正提供的工具清單，對照 AGENTS.md 的「寫入權限」規則
# 預期看到 : 工具都是檔案層級（write/edit/bash），沒有任何章節層級的粒度
#            → 那張權限表只能是「約定」，不是「執行得了的邊界」
# 為什麼重要: 升級 pi 之後如果多了新工具，攻擊面就變了，要重新檢視
# 重跑     : ./learn/08-tool-boundary.sh

IMAGE=oab-sandbox:pi
TOOLS=/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/tools

echo "=== agent 實際握有的工具（執行得了的邊界）==="
docker run --rm --entrypoint sh "$IMAGE" -c "ls $TOOLS" \
  | grep -v '\.map$\|\.d\.ts$' | sed 's/\.js$//' \
  | grep -E '^(bash|read|write|edit|find|grep|ls)$' | sed 's/^/  /'

echo
echo "=== AGENTS.md 宣稱的寫入邊界（約定）==="
sed -n '/^## 寫入權限/,/^### 來源標記/p' "$(dirname "$0")/../vault/AGENTS.md" \
  | grep '^|' | sed 's/^/  /'

echo
echo "=== 復盤區與練習區是同一個檔案的不同章節 ==="
grep -n '^## ' "$(dirname "$0")/../vault/模板/題目範本.md" | sed 's/^/  /'
