#!/bin/sh
# Bring the whole sandbox up. Every flag here came out of a measured stage --
# do not drop one casually.
#
#   S2 hardening : --read-only / --cap-drop ALL / --user / limits
#   S3 network   : --network oab-int (no route out); the only exit is oab-proxy
#   S4 keys      : no sa-key is mounted anywhere; tokens come from oab-broker
#
# Usage:
#   export DISCORD_BOT_TOKEN=<token of the *second* bot>
#   ./run.sh
#
# NOTE: this is not a long-running service. Run ./stop.sh when finished --
# production still lives on the other machine.

set -e

# Resolve mounts from this script's location, so a clone or worktree can run
# from any directory instead of requiring ~/Projects/oab-sandbox.
SANDBOX="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

if [ -z "$DISCORD_BOT_TOKEN" ]; then
    echo "DISCORD_BOT_TOKEN is not set. It must be the *second* bot token --" >&2
    echo "sharing one with production means both instances answer every message." >&2
    exit 1
fi

# --- Networks: oab-int is --internal (no route out); only oab-ext has one ---
docker network inspect oab-int >/dev/null 2>&1 || docker network create --internal oab-int
docker network inspect oab-ext >/dev/null 2>&1 || docker network create oab-ext

# --- Egress gateway ---
if ! docker ps --format '{{.Names}}' | grep -qx oab-proxy; then
    docker rm -f oab-proxy >/dev/null 2>&1 || true
    docker run -d --name oab-proxy --network oab-int \
        -v "$SANDBOX/proxy/squid.conf:/etc/squid/squid.conf:ro" \
        ubuntu/squid:latest >/dev/null
    docker network connect oab-ext oab-proxy
    echo "oab-proxy started"
fi

# --- Token broker: the only container that holds the SA key ---
if ! docker ps --format '{{.Names}}' | grep -qx oab-broker; then
    docker rm -f oab-broker >/dev/null 2>&1 || true
    docker run -d --name oab-broker --network oab-int \
        --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m \
        --cap-drop ALL --security-opt no-new-privileges --user 1000:1000 \
        --pids-limit 64 --memory 256m --memory-swap 256m \
        -e HTTPS_PROXY=http://oab-proxy:3128 \
        -e NO_PROXY=localhost,127.0.0.1,oab-proxy \
        -v "$HOME/.config/openab/sa-key.json:/run/secrets/sa-key.json:ro" \
        oab-broker:latest >/dev/null
    echo "oab-broker started"
fi

# --- Agent ---
#
# The mount list is deliberately short. Apart from these paths, the container
# sees nothing of the host:
#   config.toml     openab's config (the image's CMD hardcodes /etc/openab/config.toml)
#   pi-coach        the model wrapper
#   adc-marker.json Not a credential. It exists only to satisfy pi's fileExists
#                   gate -- see the comments in pi-coach for why.
#   vault           a separate clone, and the only writable host path
docker rm -f oab-sandbox >/dev/null 2>&1 || true
exec docker run --rm --name oab-sandbox \
    --network oab-int \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    -v oab-pi-home:/home/node/.pi \
    -v oab-openab-home:/home/node/.openab \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --user 1000:1000 \
    --pids-limit 256 \
    --memory 2g --memory-swap 2g \
    -e DISCORD_BOT_TOKEN \
    -v "$SANDBOX/config/config.toml:/etc/openab/config.toml:ro" \
    -v "$SANDBOX/config/pi-coach:/home/node/bin/pi-coach:ro" \
    -v "$SANDBOX/config/adc-marker.json:/home/node/.config/gcloud/application_default_credentials.json:ro" \
    -v "$SANDBOX/vault:/workspace" \
    oab-sandbox:pi
