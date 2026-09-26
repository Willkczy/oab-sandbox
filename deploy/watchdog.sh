#!/bin/sh
# Restart the sandbox when its Discord gateway has gone quiet.
#
# On 2026-09-26 the bot had been deaf for eight days. Every container was up,
# Docker called the agent healthy, the relay held an open tunnel to Discord, and
# squid showed that tunnel being replaced every few hours. What had not happened
# since 2026-09-18 was a single line in openab's log or a single message
# answered. The gateway session never came back after a reconnect, and nothing
# anywhere said so; one `launchctl kickstart -k` fixed it instantly.
#
# So the thing to watch is not whether anything is running. It is whether
# anything is being said.
#
# The relay carries the gateway websocket and nothing else, and Discord's
# heartbeat crosses it about every 41 seconds: measured on 2026-09-26, 409 bytes
# each way in 45 seconds. If the relay's byte counters do not move between two
# runs of this script, no heartbeat crossed, and a connection carrying no
# heartbeat is not a connection.
#
# It waits for two consecutive silent runs before acting, which at the installed
# five-minute interval means about ten minutes of silence. A healthy bot cannot
# be that quiet.
#
# Usage:
#   ./deploy/watchdog.sh          one check; the LaunchAgent runs it on a timer
#
# Overrides, which exist for learn/dev/06:
#   OAB_WATCHDOG_STATE     where the last counter is remembered
#   OAB_WATCHDOG_BYTES     a command printing the byte total, instead of the relay
#   OAB_WATCHDOG_ACTION    what to run on the decision, instead of launchctl
#   OAB_WATCHDOG_STRIKES   how many silent runs are enough (default 2)

set -eu

export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

RELAY="${OAB_RELAY:-oab-relay}"
STATE="${OAB_WATCHDOG_STATE:-$HOME/.local/state/oab-watchdog}"
STRIKES_MAX="${OAB_WATCHDOG_STRIKES:-2}"
ACTION="${OAB_WATCHDOG_ACTION:-launchctl kickstart -k gui/$(id -u)/dev.oab.sandbox}"
BYTES_CMD="${OAB_WATCHDOG_BYTES:-}"

say() { printf '%s watchdog: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }

# rx and tx together, because a stalled session stops both.
read_bytes() {
    if [ -n "$BYTES_CMD" ]; then
        sh -c "$BYTES_CMD"
        return
    fi
    docker exec "$RELAY" sh -c \
        'cat /sys/class/net/eth0/statistics/rx_bytes /sys/class/net/eth0/statistics/tx_bytes' \
        2>/dev/null | awk '{ total += $1 } END { if (NR > 0) print total }'
}

total=$(read_bytes || true)
if [ -z "$total" ]; then
    # No relay means the sandbox is down or being restarted, which is launchd's
    # job, not this one's. Saying nothing here would hide that from the log.
    say "no relay to read; leaving that to launchd"
    exit 0
fi

mkdir -p "$(dirname "$STATE")"
prev=""
strikes=0
if [ -f "$STATE" ]; then
    read -r prev strikes < "$STATE" || true
    [ -n "${strikes:-}" ] || strikes=0
fi

if [ "$total" != "$prev" ]; then
    printf '%s 0\n' "$total" > "$STATE"
    say "gateway alive (counter $total)"
    exit 0
fi

strikes=$((strikes + 1))
if [ "$strikes" -lt "$STRIKES_MAX" ]; then
    printf '%s %s\n' "$total" "$strikes" > "$STATE"
    say "no gateway traffic since the last check ($strikes of $STRIKES_MAX)"
    exit 0
fi

say "no gateway traffic across $strikes checks; restarting the sandbox"
# Reset before acting: a restart that fails should not then be repeated on every
# run, it should be visible as a counter that stays still.
printf '%s 0\n' "$total" > "$STATE"
sh -c "$ACTION"
