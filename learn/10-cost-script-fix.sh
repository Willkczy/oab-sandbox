#!/bin/sh
# 驗收：session 搬到 tmpfs 之後，pi_cost.py 還找得到正確的目錄嗎？
#
# 測什麼   : resolve_sessions_dir() 在兩種情境下各選了哪個目錄
#   情境 A : 沙箱裡（經 pi-coach 啟動）→ 應該用 /tmp/sessions
#   情境 B : 沒有 PI_SESSION_DIR 也沒有 /tmp/sessions → 應該回退到 ~/.pi/agent/sessions
# 預期看到 : 兩種情境都印出它實際掃描的目錄（不再靜默）
# 成本     : 情境 A 會真的呼叫一次 Vertex（約 $0.0001）
# 前置     : oab-proxy 與 oab-broker 要在跑
# 重跑     : ./learn/10-cost-script-fix.sh

set -e
cd "$(dirname "$0")/.."
. learn/lib/project-id.sh

run() {
    docker run --rm --network oab-int \
        --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m \
        -v oab-pi-home:/home/node/.pi \
        --cap-drop ALL --security-opt=no-new-privileges --user 1000:1000 \
        -e GOOGLE_CLOUD_PROJECT=$GCP_PROJECT \
        -e GOOGLE_CLOUD_LOCATION=global \
        -e GCE_METADATA_HOST=oab-broker:8080 \
        -e HTTPS_PROXY=http://oab-proxy:3128 \
        -e NO_PROXY=localhost,127.0.0.1,oab-proxy,oab-broker \
        -v "$PWD/config/pi-coach:/home/node/bin/pi-coach:ro" \
        -v "$PWD/config/adc-marker.json:/home/node/.config/gcloud/application_default_credentials.json:ro" \
        -v "$PWD/vault:/workspace" \
        --entrypoint sh oab-sandbox:pi -c "$1"
}

echo "########## 情境 A：沙箱裡，經 pi-coach 啟動 ##########"
run '
    cd /workspace
    /home/node/bin/pi-coach -p "只回兩個字：驗收" | sed "s/^/  模型回應: /"
    echo
    echo "  實際寫在 : $(ls /tmp/sessions/*.jsonl | tail -1)"
    echo "  --- pi_cost.py --current ---"
    PI_SESSION_DIR=/tmp/sessions python3 scripts/pi_cost.py --current | head -4 | sed "s/^/  /"
'

echo
echo "########## 情境 B：主機模式（沒有 PI_SESSION_DIR，沒有 /tmp/sessions）##########"
run '
    cd /workspace
    echo "  PI_SESSION_DIR = ${PI_SESSION_DIR:-（未設定）}"
    echo "  /tmp/sessions  = $([ -d /tmp/sessions ] && echo 存在 || echo 不存在)"
    echo "  --- pi_cost.py --current ---"
    python3 scripts/pi_cost.py --current | head -3 | sed "s/^/  /"
'
