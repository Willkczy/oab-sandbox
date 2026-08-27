#!/bin/sh
# 實驗：pi 的 --session-dir 真的會改變 session 檔的寫入位置嗎？
#
# 測什麼   : 給了 --session-dir 之後，.jsonl 落在哪、預設位置還會不會有新檔
# 預期看到 : 檔案出現在指定目錄，~/.pi/agent/sessions 沒有新增
# 為什麼重要: 這是「把 session 搬到 tmpfs 以降低誤讀成本」這個改動的前提假設
# 成本     : 會真的呼叫一次 Vertex（約 $0.0001）
# 前置     : oab-proxy 與 oab-broker 要在跑（./run.sh 或手動起）
# 重跑     : ./learn/09-session-dir.sh [session 目錄]
#            不給參數 = 用 /tmp/sessions

set -e
cd "$(dirname "$0")/.."
SESSION_DIR="${1:-/tmp/sessions}"

docker run --rm --network oab-int \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    -v oab-pi-home:/home/node/.pi \
    --cap-drop ALL --security-opt=no-new-privileges --user 1000:1000 \
    -e GOOGLE_CLOUD_PROJECT=your-gcp-project-id \
    -e GOOGLE_CLOUD_LOCATION=global \
    -e GCE_METADATA_HOST=oab-broker:8080 \
    -e HTTPS_PROXY=http://oab-proxy:3128 \
    -e NO_PROXY=localhost,127.0.0.1,oab-proxy,oab-broker \
    -e SESSION_DIR="$SESSION_DIR" \
    -v "$PWD/config/adc-marker.json:/home/node/.config/gcloud/application_default_credentials.json:ro" \
    --entrypoint sh oab-sandbox:pi -c '
        echo "=== 呼叫 pi（--session-dir $SESSION_DIR）==="
        env -u HOME pi --model google-vertex/gemini-3.6-flash \
            --session-dir "$SESSION_DIR" \
            -p "只回兩個字：收到" | sed "s/^/  模型回應: /"

        echo
        echo "=== 指定的目錄裡有什麼 ==="
        find "$SESSION_DIR" -type f 2>/dev/null | sed "s/^/  /" || echo "  （目錄不存在）"

        echo
        echo "=== 預設位置（~/.pi/agent/sessions）最近 2 分鐘有沒有新檔 ==="
        found=$(find /home/node/.pi/agent/sessions -type f -newermt "-2 minutes" 2>/dev/null)
        if [ -z "$found" ]; then
            echo "  （沒有新檔 ✅ 代表 --session-dir 生效）"
        else
            echo "$found" | sed "s/^/  ⚠️ /"
        fi
    '
