#!/bin/sh
# 驗證 run.sh 的硬化旗標真的生效。對照 notes.md S2 的實測結論。
# 改過 run.sh、升過 image、或升過 Docker Desktop 之後，重跑這支。
#
# 用法：./verify-hardening.sh
set -e
IMAGE=oab-sandbox:pi
NAME=oab-verify
FAIL=0

check() {   # check <描述> <期望值> <實際值>
    if [ "$2" = "$3" ]; then
        printf "  ✅ %-24s %s\n" "$1" "$3"
    else
        printf "  ❌ %-24s 期望 %s，實際 %s\n" "$1" "$2" "$3"
        FAIL=$((FAIL + 1))
    fi
}

# 用與 run.sh 完全相同的硬化旗標起一個探針容器。
# 這裡放假 token 是刻意的：底下要拿它示範 PID 1 的環境變數外洩。
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --entrypoint sh \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    --cap-drop ALL \
    --security-opt=no-new-privileges \
    --user 1000:1000 \
    --pids-limit 256 \
    --memory 2g --memory-swap 2g \
    -e DISCORD_BOT_TOKEN=verify-placeholder-not-a-real-token \
    "$IMAGE" -c 'sleep 120' >/dev/null

inside() { docker exec --user 1000:1000 "$NAME" sh -c "$1" 2>/dev/null; }

echo "=== S2 硬化旗標 ==="
check "capability 全清空" "0000000000000000" "$(inside 'grep ^CapEff /proc/self/status | cut -f2')"
check "非 root"          "1000"        "$(inside 'id -u')"
check "no_new_privs"     "1"           "$(inside 'grep ^NoNewPrivs /proc/self/status | cut -f2')"
check "rootfs 唯讀"      "RO"          "$(inside 'touch /usr/bin/x 2>/dev/null && echo RW || echo RO')"
check "/tmp noexec"      "1"           "$(inside 'grep " /tmp " /proc/mounts | grep -c noexec')"
check "memory 上限 2g"   "2147483648"  "$(inside 'cat /sys/fs/cgroup/memory.max')"
check "pids 上限"        "256"         "$(inside 'cat /sys/fs/cgroup/pids.max')"

echo
echo "=== PID 1 環境變數外洩（notes.md S2 已知未解）==="
# 一個「被攻陷的 agent 子行程」看得到的 PID 1 環境變數名稱清單。
# 只取變數名，不印值——這支腳本自己不該把 secret 寫進終端機。
LEAKED_KEYS=$(inside 'tr "\0" "\n" < /proc/1/environ | cut -d= -f1 | grep . | sort | tr "\n" " "')
echo "  agent 讀得到的 PID 1 變數：$LEAKED_KEYS"

# 這裡刻意沒有加判定。DISCORD_BOT_TOKEN 一定會出現在這份清單裡
# （不洩漏 bot 就不能動），所以「有沒有洩漏」不是有意義的檢查項。
# 未決：要不要改成斷言「這是唯一的一個 secret」——若哪天有人在 run.sh
# 加了 -e GOOGLE_APPLICATION_CREDENTIALS 之類的就亮紅燈。

docker rm -f "$NAME" >/dev/null 2>&1 || true
echo
if [ "$FAIL" -eq 0 ]; then
    echo "全部通過。"
else
    echo "$FAIL 項未通過 —— 不要在這個狀態下跑 run.sh。"
    exit 1
fi
