#!/bin/sh
# launchd's entry point for the sandbox. Three things have to happen in order,
# and launchd does none of them for you.
#
#   1. PATH. launchd hands a process /usr/bin:/bin:/usr/sbin:/sbin and nothing
#      else, so colima and docker in ~/.local/bin are invisible unless named here.
#   2. The container runtime. At login this agent starts before colima's VM is
#      up, and `docker run` against a dead socket fails immediately -- which
#      launchd would treat as a crash and retry, and the retries would be the
#      only record. So it waits, and gives up loudly.
#   3. The token. DISCORD_BOT_TOKEN lives in the environment file production
#      already used. It is read here rather than written into the plist, because
#      a plist is world-readable and that file is not.
set -eu

SANDBOX="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TOKEN_ENV="${OAB_TOKEN_ENV:-$HOME/.config/openab/env.sh}"
RUNTIME_WAIT="${OAB_RUNTIME_WAIT:-300}"

export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

if [ ! -f "$TOKEN_ENV" ]; then
    echo "no environment file at $TOKEN_ENV, so there is no bot token to run with" >&2
    exit 78   # EX_CONFIG: launchd will not hammer a configuration error
fi
# shellcheck disable=SC1090
. "$TOKEN_ENV"

if [ -z "${DISCORD_BOT_TOKEN:-}" ]; then
    echo "$TOKEN_ENV does not set DISCORD_BOT_TOKEN" >&2
    exit 78
fi

waited=0
until docker info >/dev/null 2>&1; do
    if [ "$waited" -ge "$RUNTIME_WAIT" ]; then
        echo "the container runtime did not come up within ${RUNTIME_WAIT}s" >&2
        exit 75   # EX_TEMPFAIL: worth retrying, unlike the two above
    fi
    sleep 5
    waited=$((waited + 5))
done
[ "$waited" -eq 0 ] || echo "waited ${waited}s for the container runtime"

exec "$SANDBOX/run.sh"
