#!/bin/sh
# 實驗：訊息是怎麼從 Discord 一路送到 pi 的？
#
# 測什麼   : openab → pi-acp → pi 這三段之間，用什麼載體、什麼格式傳訊息
# 預期看到 : 全程是行程的 stdin/stdout 管線，格式是每行一個 JSON 物件
#            （不是 HTTP、不是 socket、不是檔案）
# 為什麼重要: 這個選擇決定了它們必須是父子行程 → 直接導致 notes.md S2 那個
#            /proc/1/environ 洩漏補不起來
# 重跑     : ./learn/06-message-path-to-pi.sh
#
# 升級 pi-acp 之後可以重跑這支，確認接線方式沒變。

IMAGE=oab-sandbox:pi
inimage() { docker run --rm --entrypoint sh "$IMAGE" -c "$1"; }

echo "=== 1. pi-acp 是什麼東西 ==="
inimage 'head -5 /usr/local/bin/pi-acp'

echo
echo "=== 2. 對上游（openab）：用 stdin/stdout，格式是 ndJSON ==="
inimage 'grep -n "ndJsonStream\|process.stdin.on\|process.stdout.write" /usr/local/bin/pi-acp | head -5'

echo
echo "=== 3. 對下游（pi）：spawn 的指令與管線設定 ==="
inimage 'sed -n "133,142p" /usr/local/bin/pi-acp'

echo
echo "=== 4. 中間那層 wrapper 做了什麼 ==="
echo "  $(tail -1 "$(dirname "$0")/../config/pi-coach")"
echo "  ↑ exec 會「取代」目前這個 shell 行程，不是再生一個子行程，"
echo "    所以 pi 直接繼承 pi-acp 開好的那組管線，中間沒有多一層。"
