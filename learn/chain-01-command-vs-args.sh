#!/bin/sh
# ─────────────────────────────────────────────────────────────────────
# 呼叫鏈支線 01：「程式名」和「參數」是分開的兩格
#
# 測什麼：
#   同樣一串文字 "greet --loud 早安"，
#   用兩種不同方式去啟動，結果完全不一樣。
#
# 預期看到：
#   [1] 經過 shell     → 成功。shell 幫你把字串切成 程式名 + 2 個參數
#   [2] 不經過 shell   → 失敗。整串文字被當成一個檔名，找不到
#   [3] 包一層 wrapper → 成功。參數改成寫在檔案「裡面」
#
# 為什麼重要：
#   pi-acp 啟動 pi 用的正是 [2] 那種方式（不經過 shell），
#   所以這個專案才需要 config/pi-coach 這支 wrapper。
#
# 這個實驗完全不碰 docker，也不改動專案任何東西（只用暫存目錄）。
#
# 怎麼重跑：  ./learn/chain-01-command-vs-args.sh
# ─────────────────────────────────────────────────────────────────────
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 先自製一支假程式 greet，它唯一的工作是回報「我收到了哪些參數」
cat > "$WORK/greet" <<'EOF'
#!/bin/sh
echo "    ✓ greet 啟動成功！我收到 $# 個參數：$*"
EOF
chmod +x "$WORK/greet"

# 讓系統找得到剛做好的 greet
PATH="$WORK:$PATH"
export PATH


echo "═══ [1] 經過 shell 啟動 ═══"
echo '    做法：sh -c "greet --loud 早安"'
sh -c "greet --loud 早安"
echo


echo "═══ [2] 不經過 shell 啟動（pi-acp 用的方式）═══"
echo '    做法：把整串 "greet --loud 早安" 塞進「程式名」那一格'
python3 "$HERE/lib/spawn_demo.py" "greet --loud 早安"
echo


echo "═══ [3] 一樣不經過 shell，但先做一支 wrapper 檔案 ═══"
# wrapper 的內容：把參數寫死在檔案裡面
cat > "$WORK/greet-loud" <<'EOF'
#!/bin/sh
exec greet --loud 早安 "$@"
EOF
chmod +x "$WORK/greet-loud"

echo '    先做一支叫 greet-loud 的檔案，內容是：'
echo '        exec greet --loud 早安 "$@"'
echo '    然後「程式名」那一格只放一個乾淨的檔名：greet-loud'
python3 "$HERE/lib/spawn_demo.py" "greet-loud"
