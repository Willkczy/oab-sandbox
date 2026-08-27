#!/bin/sh
# Experiment: how does a message actually travel from Discord to pi?
#
# What it tests  : what carries the message across openab -> pi-acp -> pi, and in
#                  what format
# What to expect : stdin/stdout pipes the whole way, one JSON object per line.
#                  Not HTTP, not sockets, not files.
# Why it matters : that choice forces them to be parent and child processes,
#                  which is precisely why the /proc/1/environ leak recorded under
#                  S2 in notes.md cannot be closed
# Re-run         : ./learn/06-message-path-to-pi.sh
#
# Worth re-running after a pi-acp upgrade, to confirm the wiring has not changed.

IMAGE=oab-sandbox:pi
inimage() { docker run --rm --entrypoint sh "$IMAGE" -c "$1"; }

echo "=== 1. What pi-acp actually is ==="
inimage 'head -5 /usr/local/bin/pi-acp'

echo
echo "=== 2. Upstream (openab): stdin/stdout, ndJSON on the wire ==="
inimage 'grep -n "ndJsonStream\|process.stdin.on\|process.stdout.write" /usr/local/bin/pi-acp | head -5'

echo
echo "=== 3. Downstream (pi): the spawn call and its pipe setup ==="
inimage 'sed -n "133,142p" /usr/local/bin/pi-acp'

echo
echo "=== 4. What the wrapper in between does ==="
echo "  $(tail -1 "$(dirname "$0")/../config/pi-coach")"
echo "  ^ exec *replaces* this shell process rather than forking another one,"
echo "    so pi inherits the pipes pi-acp already opened. No extra layer."
