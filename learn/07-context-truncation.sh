#!/bin/sh
# 實驗：AGENTS.md 那個 sed 到底切掉了什麼？
#
# 測什麼   : 抓回來的題目頁面，被 sed '/^Topics$/,$d' 切掉的是哪些內容
# 預期看到 : Topics 之後緊接著 pattern 分類、複雜度建議、Hint 1/2/3
#            —— 全都是教練規則明文禁止提前揭露的東西
# 為什麼重要: 這是整套系統唯一把「外部網頁」拉進 context 的地方，
#            也就是唯一的 prompt injection 入口
# 重跑     : ./learn/07-context-truncation.sh [題目網址]
#
# 注意：會對 r.jina.ai 發一次請求（免金鑰，速率限制 60 秒 20 次）。

set -e
URL="${1:-https://neetcode.io/problems/buy-and-sell-crypto/question?list=neetcode150}"

RAW=$(mktemp)
trap 'rm -f "$RAW"' EXIT

echo "抓取：$URL"
curl -s --max-time 60 "https://r.jina.ai/$URL" > "$RAW"

full=$(wc -l < "$RAW" | tr -d ' ')
kept=$(sed '/^Topics$/,$d' "$RAW" | wc -l | tr -d ' ')

echo
echo "=== 尺寸 ==="
printf "  原始頁面    %4s 行\n" "$full"
printf "  sed 之後    %4s 行   （切掉 %s 行）\n" "$kept" "$((full - kept))"

echo
echo "=== 留下來的結尾（進得了 context 的最後幾行）==="
sed '/^Topics$/,$d' "$RAW" | tail -6 | sed 's/^/  │ /'

echo
echo "=== 被切掉的部分（根本不進 context）==="
sed -n '/^Topics$/,$p' "$RAW" | head -24 | sed 's/^/  ✂ /'
