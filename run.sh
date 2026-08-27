#!/bin/sh
# 沙箱整組啟動。每一個旗標都是某一階實測出來的，不要隨手拿掉。
#
#   S2 硬化    : --read-only / --cap-drop ALL / --user / limits
#   S3 網路    : --network oab-int（無對外路由），出口只有 oab-proxy
#   S4 金鑰    : 沒有任何 sa-key 掛載；token 走 oab-broker
#
# 用法：
#   export DISCORD_BOT_TOKEN=<第二個 bot 的 token>
#   ./run.sh
#
# ⚠️ 這不是常駐服務。練完 ./stop.sh，production 仍在舊機上。

set -e
SANDBOX="$HOME/Projects/oab-sandbox"

if [ -z "$DISCORD_BOT_TOKEN" ]; then
    echo "沒有 DISCORD_BOT_TOKEN。這必須是「第二個」bot 的 token ——" >&2
    echo "與舊機 production 共用同一個會雙重回應。" >&2
    exit 1
fi

# --- 網路：oab-int 是 --internal（沒有對外路由），oab-ext 才有 ---
docker network inspect oab-int >/dev/null 2>&1 || docker network create --internal oab-int
docker network inspect oab-ext >/dev/null 2>&1 || docker network create oab-ext

# --- 出口閘門 ---
if ! docker ps --format '{{.Names}}' | grep -qx oab-proxy; then
    docker rm -f oab-proxy >/dev/null 2>&1 || true
    docker run -d --name oab-proxy --network oab-int \
        -v "$SANDBOX/proxy/squid.conf:/etc/squid/squid.conf:ro" \
        ubuntu/squid:latest >/dev/null
    docker network connect oab-ext oab-proxy
    echo "oab-proxy 已啟動"
fi

# --- token broker：唯一持有 SA 金鑰的容器 ---
if ! docker ps --format '{{.Names}}' | grep -qx oab-broker; then
    docker rm -f oab-broker >/dev/null 2>&1 || true
    docker run -d --name oab-broker --network oab-int \
        --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m \
        --cap-drop ALL --security-opt no-new-privileges --user 1000:1000 \
        --pids-limit 64 --memory 256m --memory-swap 256m \
        -e HTTPS_PROXY=http://oab-proxy:3128 \
        -e NO_PROXY=localhost,127.0.0.1,oab-proxy \
        -v "$HOME/.config/openab/sa-key.json:/run/secrets/sa-key.json:ro" \
        oab-broker:latest >/dev/null
    echo "oab-broker 已啟動"
fi

# --- agent ---
#
# 掛載清單刻意很短。除了這幾個路徑，容器裡看不到主機的任何東西：
#   config.toml     openab 的設定（image 的 CMD 寫死讀 /etc/openab/config.toml）
#   pi-coach        模型 wrapper
#   adc-marker.json 不是憑證。只為滿足 pi 的 fileExists 閘門，理由見 pi-coach 註解
#   vault           獨立 clone，唯一可寫的主機路徑
docker rm -f oab-sandbox >/dev/null 2>&1 || true
exec docker run --rm --name oab-sandbox \
    --network oab-int \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    -v oab-pi-home:/home/node/.pi \
    -v oab-openab-home:/home/node/.openab \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --user 1000:1000 \
    --pids-limit 256 \
    --memory 2g --memory-swap 2g \
    -e DISCORD_BOT_TOKEN \
    -v "$SANDBOX/config/config.toml:/etc/openab/config.toml:ro" \
    -v "$SANDBOX/config/pi-coach:/home/node/bin/pi-coach:ro" \
    -v "$SANDBOX/config/adc-marker.json:/home/node/.config/gcloud/application_default_credentials.json:ro" \
    -v "$SANDBOX/vault:/workspace" \
    oab-sandbox:pi
