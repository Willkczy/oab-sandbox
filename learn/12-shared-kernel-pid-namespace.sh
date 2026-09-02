#!/bin/sh
# Experiment: a container is not a small VM. It shares the host's kernel, and
# what looks like isolation is a renumbered view of that one kernel.
#
# What it tests  : (1) whether two unrelated images report the same kernel, and
#                  whether that kernel is the one the Mac itself runs
#                  (2) whether a single process has two different PIDs at the
#                  same moment, depending on which namespace is looking
# What to expect : both containers print the same Linux version, and it is not
#                  the Darwin uname reports on the host; the same sleep process
#                  is PID 1 inside its container and a large number outside
# Why it matters : every S2 flag in run.sh -- cap-drop, no-new-privileges,
#                  read-only -- exists because there is only one kernel here to
#                  compromise. A real VM would not need any of them. This is the
#                  property that makes the rest of the hardening necessary
# Cost           : none; no model is called
# Re-run         : ./learn/12-shared-kernel-pid-namespace.sh
#
# Uses alpine on purpose: a different distro from oab-sandbox:pi, so "same
# kernel" cannot be explained away as "same image". It is pulled if missing.

set -e
cd "$(dirname "$0")/.."

NAME=oab-pidns-demo
SLEEP_SECS=47

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "=== [1] One kernel, three points of view ==="
printf "  this machine          : "
uname -s -r
printf "  oab-sandbox:pi says   : "
docker run --rm --entrypoint sh oab-sandbox:pi -c 'uname -s -r'
printf "  alpine says           : "
docker run --rm alpine uname -s -r
echo
echo "  The two containers ship different distros and report the same kernel,"
echo "  and neither reports the host's. A container brings its own files, not"
echo "  its own kernel; on a Mac the kernel they share lives in Docker's VM."

echo
echo "=== [2] The same process, counted twice ==="
docker run -d --rm --name "$NAME" alpine sleep "$SLEEP_SECS" >/dev/null
sleep 1

echo "  inside its own PID namespace:"
docker exec "$NAME" ps -eo pid,args | sed 's/^/    /'

echo
echo "  from the host's PID namespace:"
# TODO(human): print the line for that same sleep process as the host sees it.
#
# What you have to work with:
#   - the container is named "$NAME" and is running `sleep $SLEEP_SECS`
#   - `docker run --rm --pid=host alpine ps -eo pid,args` lists every process
#     in the host's namespace (about 190 of them, so it needs narrowing)
#   - `docker inspect` also knows things about a running container
#
# Print one line, indented four spaces to match the block above, showing the
# host-side PID of that sleep. Leave HOST_VIEW empty if nothing matched, so the
# check below can report an honest failure rather than a blank.
HOST_VIEW=""

if [ -n "$HOST_VIEW" ]; then
    echo "$HOST_VIEW" | sed 's/^/    /'
else
    echo "    (nothing matched -- see the handoff comment above)"
fi

echo
echo "  One process. PID 1 to itself, something else to the kernel that actually"
echo "  schedules it. The namespace did not move the process anywhere; it only"
echo "  changed which numbers it is allowed to see."
