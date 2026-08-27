#!/bin/sh
# 停掉整組沙箱。volume 與網路保留，下次 run.sh 直接接上。
# 要連 volume 一起清：docker volume rm oab-pi-home oab-openab-home
set -e
docker rm -f oab-sandbox oab-broker oab-proxy >/dev/null 2>&1 || true
echo "沙箱已停。舊機的 production 不受影響。"
