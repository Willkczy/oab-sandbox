#!/bin/sh
# ── What this accepted ────────────────────────────────────────────────
# openab keeps its Discord thread map, reminders and cache in ~/.openab, which
# run.sh mounts as the named volume oab-openab-home. The base image had no such
# directory, so Docker created the root of that volume owned by root, and openab,
# running as uid 1000, logged `failed to persist thread mapping ... Permission
# denied` on every session. The Dockerfile now creates the directory owned by node.
#
# The claim has two halves, and the second is the one that matters on a machine
# that has already run the sandbox:
#
#   1. a new volume mounted at ~/.openab comes up owned by uid 1000
#   2. an existing volume whose root is owned by root, but which is empty, is
#      re-owned by uid 1000 the first time the new image mounts it there
#
# Half 2 rests on Docker copying an image directory's ownership onto an empty
# named volume. A volume that already holds files keeps its ownership, which is
# acceptable here only because openab could never write to the real one.
#
# ── What to expect ────────────────────────────────────────────────────
#   the image            /home/node/.openab exists, owned by 1000
#   the old state        a volume mounted where the image has no directory: 0, not writable
#   half 1, new volume   1000, writable
#   half 2, that volume  1000, writable
#
# ── How to re-run ─────────────────────────────────────────────────────
#   docker build -t oab-sandbox:pi .          # the image under test
#   ./learn/dev/04-openab-state-volume.sh
#
# Costs nothing. The volumes are named oab-d04-* and removed on exit. The real
# oab-openab-home is never mounted.

set -eu

IMAGE=oab-sandbox:pi
FRESH=oab-d04-fresh
STALE=oab-d04-stale
FAIL=0

cleanup() {
    docker volume rm -f "$FRESH" "$STALE" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
cleanup

# owner_and_access <volume> <mount path>
# Tries to write as uid 1000 first, because that first mount is the one that
# decides the volume's ownership, then reports the owner of the volume's root.
owner_and_access() {
    if docker run --rm --network none --user 1000:1000 -v "$1:$2" \
        --entrypoint touch "$IMAGE" "$2/probe" >/dev/null 2>&1; then
        access=writable
    else
        access="not writable"
    fi
    owner=$(docker run --rm --network none -v "$1:$2" --entrypoint stat "$IMAGE" -c %u "$2")
    echo "$owner, $access"
}

report() {   # report <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok %-34s %s\n' "$1" "$3"
    else
        printf '  X  %-34s expected %s, got %s\n' "$1" "$2" "$3"
        FAIL=$((FAIL + 1))
    fi
}

in_image=$(docker run --rm --network none --entrypoint stat "$IMAGE" -c %u /home/node/.openab 2>/dev/null || echo "missing")
report "the image: /home/node/.openab" "1000" "$in_image"

docker volume create "$STALE" >/dev/null
report "the old state" "0, not writable" "$(owner_and_access "$STALE" /home/node/.not-in-image)"

docker volume create "$FRESH" >/dev/null
report "half 1, new volume" "1000, writable" "$(owner_and_access "$FRESH" /home/node/.openab)"

report "half 2, the root-owned volume" "1000, writable" "$(owner_and_access "$STALE" /home/node/.openab)"

echo
if [ "$FAIL" -eq 0 ]; then
    echo "all checks passed."
else
    echo "$FAIL check(s) failed."
    exit 1
fi
