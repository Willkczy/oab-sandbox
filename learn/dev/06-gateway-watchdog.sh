#!/bin/sh
# ── What this accepted ────────────────────────────────────────────────
# On 2026-09-26 the bot had been deaf for eight days: every container up, Docker
# calling the agent healthy, an open tunnel to Discord being replaced every few
# hours, and not one line in openab's log or one message answered since
# 2026-09-18. deploy/watchdog.sh restarts the sandbox when the gateway stops
# carrying heartbeats, which is the one signal that separates a live session from
# a live socket.
#
# What is checked here is the decision, not the plumbing: when it waits, when it
# acts, and that it does not act twice for one outage. The byte counter is fed in
# through OAB_WATCHDOG_BYTES rather than read from a relay, because a test that
# needed a real gateway to fall over could not be run on demand -- and the
# counter is the only thing the script gets from the relay anyway.
#
# The relay end of it was measured directly instead: on the machine that runs the
# bot, the relay's rx and tx counters each moved 409 bytes in 45 seconds, which
# is Discord's heartbeat and nothing else.
#
# ── What to expect ────────────────────────────────────────────────────
#   1  first run, no state yet          alive, no action
#   2  counter moved                    alive, no action
#   3  counter still, first time        waits, says 1 of 2
#   4  counter still, second time       acts
#   5  counter still, right after       waits again, does not act twice
#   6  counter moved after a restart    alive again
#   7  no relay to read                 says so, exits 0, does not act
#
# ── How to re-run ─────────────────────────────────────────────────────
#   ./learn/dev/06-gateway-watchdog.sh
#
# Costs nothing, needs no containers and no secret. Works in learn/out/dev06.

set -eu

SANDBOX="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
WATCHDOG="$SANDBOX/deploy/watchdog.sh"
WORK="$SANDBOX/learn/out/dev06"
STATE="$WORK/state"
ACTED="$WORK/acted"
FAIL=0

rm -rf "$WORK"
mkdir -p "$WORK"

set +e

# run <bytes> : one check with that counter value, printing what it said
run() {
    if [ "$1" = "none" ]; then
        bytes="true"          # prints nothing, as a missing relay does
    else
        bytes="echo $1"
    fi
    OAB_WATCHDOG_STATE="$STATE" \
    OAB_WATCHDOG_BYTES="$bytes" \
    OAB_WATCHDOG_ACTION="touch $ACTED" \
        sh "$WATCHDOG" 2>&1
}

# check <number> <description> <expected phrase> <expected action: acts|quiet>
check() {
    out=$(run "$5")
    if [ -f "$ACTED" ]; then acted=acts; else acted=quiet; fi
    rm -f "$ACTED"

    if printf '%s\n' "$out" | grep -q -- "$3" && [ "$acted" = "$4" ]; then
        printf '  %s %-34s %-6s PASS\n' "$1" "$2" "$acted"
    else
        printf '  %s %-34s %-6s FAIL (wanted "%s" and %s)\n' "$1" "$2" "$acted" "$3" "$4"
        printf '       said: %s\n' "$out"
        FAIL=$((FAIL + 1))
    fi
}

echo "script under test: $WATCHDOG"
echo

check 1 "first run, no state yet"        "gateway alive"           quiet 1000
check 2 "counter moved"                  "gateway alive"           quiet 1500
check 3 "counter still, first time"      "1 of 2"                  quiet 1500
check 4 "counter still, second time"     "restarting the sandbox"  acts  1500
check 5 "counter still, right after"     "1 of 2"                  quiet 1500
check 6 "counter moved after a restart"  "gateway alive"           quiet 2600
check 7 "no relay to read"               "no relay to read"        quiet none

echo
if [ "$FAIL" -eq 0 ]; then
    echo "all seven scenarios passed."
else
    echo "$FAIL scenario(s) failed."
    exit 1
fi
