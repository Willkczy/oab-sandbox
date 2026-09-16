#!/bin/sh
# ── What this accepted ────────────────────────────────────────────────
# run.sh used to reuse oab-proxy, oab-relay and oab-broker whenever a container
# with that name was running. On 2026-09-15 that kept a squid started from an
# older squid.conf, and the Discord bot stayed offline behind the old allowlist,
# with no error anywhere openab logs by default (finding 8).
#
# run.sh now starts each of those through start_service(), which labels the
# container with a fingerprint of its image ID, its docker run arguments and the
# config file it mounts, and recreates any running container whose label does not
# match what this run would start.
#
# This script runs run.sh's own start_service() against a throwaway container
# instead of running run.sh. run.sh hardcodes the oab-* names, so running it here
# would replace a live sandbox. Extracting the function tests the same text
# without touching one.
#
# ── What to expect ────────────────────────────────────────────────────
# Six scenarios, each with the verdict start_service() returned, whether the
# container ID changed, whether it explained itself, and PASS or FAIL:
#
#   1 nothing running                      started  new id  silent
#   2 run again, nothing changed           reused   same id silent
#   3 the mounted config file changed      started  new id  explains
#   4 a docker run flag changed            started  new id  explains
#   5 running with no label (old run.sh)   started  new id  explains
#   6 stopped, label matches               started  new id  silent
#
# Scenario 3 is the 2026-09-15 failure. Scenario 5 is what the first run.sh after
# this change does to a sandbox that an older run.sh started.
#
# ── How to re-run ─────────────────────────────────────────────────────
#   ./learn/dev/03-stale-service-containers.sh
#
# Costs nothing. Needs Docker and alpine:3.24, which it pulls if absent. The
# container is named oab-d03-svc and removed on exit.

set -eu

SANDBOX="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
NAME=oab-d03-svc
IMAGE=alpine:3.24
WORK="$SANDBOX/learn/out/dev03"
CONF="$WORK/service.conf"
FAIL=0

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
cleanup

# The function is lifted out of run.sh verbatim. If it has been renamed or moved,
# say so rather than testing nothing.
FN=$(sed -n '/^start_service() {$/,/^}$/p' "$SANDBOX/run.sh")
if [ -z "$FN" ]; then
    echo "start_service() was not found in run.sh, so there is nothing to test." >&2
    exit 1
fi
eval "$FN"

docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null
mkdir -p "$WORK"
echo "version 1" > "$CONF"

container_id() {
    docker inspect -f '{{.Id}}' "$NAME" 2>/dev/null | cut -c1-12 || true
}

# The service under test, started the way run.sh starts its own: a config file
# mounted read-only, flags, the image, a command. $1 is the memory ceiling, the
# flag scenario 4 changes.
start_with() {
    start_service "$NAME" "$IMAGE" "$CONF" \
        --network none --memory "$1" --memory-swap "$1" \
        -v "$CONF:/etc/service.conf:ro" \
        "$IMAGE" sleep 600
}

# scenario <number> <description> <memory> <expected verdict> <expected id> <expected message>
scenario() {
    before=$(container_id)
    if out=$(start_with "$3"); then verdict=started; else verdict=reused; fi
    after=$(container_id)

    if [ "$before" = "$after" ]; then id="same id"; else id="new id"; fi
    if [ -n "$out" ]; then message=explains; else message=silent; fi

    if [ "$verdict" = "$4" ] && [ "$id" = "$5" ] && [ "$message" = "$6" ]; then
        result=PASS
    else
        result="FAIL (expected $4, $5, $6)"
        FAIL=$((FAIL + 1))
    fi
    printf '  %s %-36s %-8s %-7s %-8s %s\n' "$1" "$2" "$verdict" "$id" "$message" "$result"
    if [ -n "$out" ]; then
        echo "      says: $out"
    fi
}

echo "function under test: start_service() from $SANDBOX/run.sh"
echo

scenario 1 "nothing running" 32m started "new id" silent

scenario 2 "run again, nothing changed" 32m reused "same id" silent

echo "version 2" > "$CONF"
scenario 3 "the mounted config file changed" 32m started "new id" explains

scenario 4 "a docker run flag changed" 64m started "new id" explains

# What an older run.sh left behind: the same container, started without a label.
docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" --network none --memory 64m --memory-swap 64m \
    -v "$CONF:/etc/service.conf:ro" "$IMAGE" sleep 600 >/dev/null
scenario 5 "running with no label (old run.sh)" 64m started "new id" explains

docker stop -t 0 "$NAME" >/dev/null
scenario 6 "stopped, label matches" 64m started "new id" silent

echo
if [ "$FAIL" -eq 0 ]; then
    echo "all six scenarios passed."
else
    echo "$FAIL scenario(s) failed."
    exit 1
fi
