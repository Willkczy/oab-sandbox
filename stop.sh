#!/bin/sh
# Stop the whole sandbox. Volumes and networks are left in place, so the next
# run.sh picks up where this left off.
# To clear the volumes too: docker volume rm oab-pi-home oab-openab-home
set -e

# Derived from this script's own location rather than hardcoded, so the archive
# lands next to the copy of the repo being run -- including a worktree.
SANDBOX="$(cd "$(dirname "$0")" && pwd)"
ARCHIVE="$SANDBOX/learn/out/archive"

# --- Keep the session log before the container takes it with it ---
#
# pi writes its sessions to a tmpfs; config/pi-coach explains why, and the cost
# it accepts is that `docker run --rm` discards that history on every stop.
#
# That cost is only worth paying because the history can be moved out first. The
# agent still sees nothing but the current session -- the property tmpfs was
# chosen for -- while the full record survives on the host, where the agent
# cannot reach it. What makes that true is that learn/ is absent from run.sh's
# mount list. Mounting it would hand the accumulated history straight back and
# undo the point of the tmpfs.
#
# `docker cp` cannot do this. It reads the container's filesystem layers, and a
# tmpfs mount is not one of them; it fails with "Could not find the file
# /tmp/sessions in container". Streaming a tar out of `docker exec` works.
#
# Still uncovered: a container that dies on its own -- OOM, a crash -- is gone
# along with its log before this ever runs, which is exactly when that log would
# have been worth the most.
if docker ps --format '{{.Names}}' | grep -qx oab-sandbox; then
    DEST="$ARCHIVE/$(date +%Y-%m-%dT%H-%M-%S)"
    mkdir -p "$DEST"
    docker exec oab-sandbox tar -cf - -C /tmp sessions 2>/dev/null \
        | tar -xf - -C "$DEST" 2>/dev/null || true
    if [ -n "$(ls -A "$DEST/sessions" 2>/dev/null)" ]; then
        echo "session log archived to ${DEST#"$SANDBOX"/}"
    else
        rm -rf "$DEST"
        echo "no session log to archive -- the agent never wrote one"
    fi
fi

docker rm -f oab-sandbox oab-relay oab-broker oab-proxy >/dev/null 2>&1 || true
echo "sandbox stopped. production on the other machine is unaffected."
