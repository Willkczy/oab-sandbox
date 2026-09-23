#!/bin/sh
# Verify that run.sh's hardening flags actually took effect, against the
# measured conclusions recorded under S2 in docs/build-log.zh.md. Re-run this
# after any change to run.sh, any image rebuild, or any Docker Desktop upgrade.
#
# Usage: ./verify-hardening.sh
set -e
IMAGE=oab-sandbox:pi
NAME=oab-verify
RELAY_IMAGE=oab-relay:latest
RELAY_NAME=oab-verify-relay
FAIL=0

check() {   # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf "  ok %-24s %s\n" "$1" "$3"
    else
        printf "  X %-24s expected %s, got %s\n" "$1" "$2" "$3"
        FAIL=$((FAIL + 1))
    fi
}

# Start a probe container with exactly the hardening flags run.sh uses.
# The fake token is deliberate -- it is what the PID 1 environment leak below
# is demonstrated with.
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

# The relay gets the same treatment with its own, smaller ceilings. Its image's
# entrypoint is socat, so the probe overrides it to keep the container idle.
docker rm -f "$RELAY_NAME" >/dev/null 2>&1 || true
docker run -d --name "$RELAY_NAME" --entrypoint sh \
    --read-only \
    --cap-drop ALL \
    --security-opt=no-new-privileges \
    --user 1000:1000 \
    --pids-limit 32 \
    --memory 32m --memory-swap 32m \
    "$RELAY_IMAGE" -c 'sleep 120' >/dev/null

inside() { docker exec --user 1000:1000 "$NAME" sh -c "$1" 2>/dev/null; }
in_relay() { docker exec --user 1000:1000 "$RELAY_NAME" sh -c "$1" 2>/dev/null; }

echo "=== S2 hardening flags ==="
check "capabilities empty" "0000000000000000" "$(inside 'grep ^CapEff /proc/self/status | cut -f2')"
check "non-root"            "1000"        "$(inside 'id -u')"
check "no_new_privs"        "1"           "$(inside 'grep ^NoNewPrivs /proc/self/status | cut -f2')"
check "rootfs read-only"    "RO"          "$(inside 'touch /usr/bin/x 2>/dev/null && echo RW || echo RO')"
check "/tmp noexec"         "1"           "$(inside 'grep " /tmp " /proc/mounts | grep -c noexec')"
check "memory limit 2g"     "2147483648"  "$(inside 'cat /sys/fs/cgroup/memory.max')"
check "pids limit"          "256"         "$(inside 'cat /sys/fs/cgroup/pids.max')"

echo
echo "=== S2 hardening flags, relay ==="
check "capabilities empty" "0000000000000000" "$(in_relay 'grep ^CapEff /proc/self/status | cut -f2')"
check "non-root"            "1000"        "$(in_relay 'id -u')"
check "no_new_privs"        "1"           "$(in_relay 'grep ^NoNewPrivs /proc/self/status | cut -f2')"
check "rootfs read-only"    "RO"          "$(in_relay 'touch /usr/bin/x 2>/dev/null && echo RW || echo RO')"
check "memory limit 32m"    "33554432"    "$(in_relay 'cat /sys/fs/cgroup/memory.max')"
check "pids limit"          "32"          "$(in_relay 'cat /sys/fs/cgroup/pids.max')"
# socat listens on 443 as uid 1000 with no capabilities. That works only because
# Docker sets this sysctl to 0 inside each container's network namespace. If an
# upgrade stops doing so, the relay cannot bind, and the gateway goes with it.
check "443 bindable unprivileged" "0"     "$(in_relay 'cat /proc/sys/net/ipv4/ip_unprivileged_port_start')"

echo
echo "=== PID 1 environment leak (open issue, see S2 in docs/build-log.zh.md) ==="
# The list of PID 1 environment variable names a compromised agent child
# process can read. Names only, never values -- this script has no business
# writing a secret to the terminal itself.
LEAKED_KEYS=$(inside 'tr "\0" "\n" < /proc/1/environ | cut -d= -f1 | grep . | sort | tr "\n" " "')
echo "  PID 1 vars readable by the agent: $LEAKED_KEYS"

# There is deliberately no assertion here. DISCORD_BOT_TOKEN will always be in
# this list -- the bot cannot run without it -- so "did anything leak" is not a
# meaningful check. Open question: turn this into an assertion that it is the
# *only* secret present, so that adding something like
# -e GOOGLE_APPLICATION_CREDENTIALS to run.sh would light up red.

docker rm -f "$NAME" "$RELAY_NAME" >/dev/null 2>&1 || true
echo
if [ "$FAIL" -eq 0 ]; then
    echo "all checks passed."
else
    echo "$FAIL check(s) failed -- do not run run.sh in this state."
    exit 1
fi
