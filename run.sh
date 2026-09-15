#!/bin/sh
# Bring the whole sandbox up. Every flag here came out of a measured stage --
# do not drop one casually.
#
#   S2 hardening : --read-only / --cap-drop ALL / --user / limits
#   S3 network   : --network oab-int (no route out); the only exit is oab-proxy,
#                  and oab-relay carries the Discord gateway to that same exit
#   S4 keys     : no sa-key is mounted anywhere; tokens come from oab-broker
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

# --- Discord gateway relay: the websocket's way to the same exit ---
#
# openab's gateway client ignores HTTPS_PROXY and dials gateway.discord.gg
# itself (finding 8). The agent is told that name belongs to this container, and
# socat forwards each connection to squid as a CONNECT tunnel, so the websocket
# leaves through the exit everything else uses. relay/Dockerfile says why TLS
# stays end to end.
#
# The name is spoofed with --add-host on the agent alone, never with
# --network-alias. Docker's DNS answers an alias for every container on oab-int,
# squid included: squid then resolves gateway.discord.gg to the relay, and the two
# tunnel into each other until the relay's pids-limit stops them. Measured on
# 2026-09-15. squid.conf's private_dst rule is the backstop for that mistake.
if ! docker ps --format '{{.Names}}' | grep -qx oab-relay; then
    docker rm -f oab-relay >/dev/null 2>&1 || true
    docker run -d --name oab-relay --network oab-int \
        --read-only \
        --cap-drop ALL --security-opt no-new-privileges --user 1000:1000 \
        --pids-limit 32 --memory 32m --memory-swap 32m \
        oab-relay:latest -d -d TCP-LISTEN:443,fork,reuseaddr \
        PROXY:oab-proxy:gateway.discord.gg:443,proxyport=3128 >/dev/null
    echo "oab-relay started"
fi

# The relay's address is read at every start rather than written down, because
# oab-int has no configured subnet and Docker assigns it. The agent below is
# always recreated after this line, so its hosts entry names the current address.
RELAY_IP=$(docker inspect -f '{{with index .NetworkSettings.Networks "oab-int"}}{{.IPAddress}}{{end}}' oab-relay)
if [ -z "$RELAY_IP" ]; then
    echo "oab-relay has no address on oab-int, so the gateway would fail silently." >&2
    exit 1
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
#
# The proxy variables here are openab's own, for its REST half. The copy in
# config.toml's [agent] env is pi's: openab clears the environment of the agent
# subprocess, so neither copy reaches the other process (finding 8, layer 1).
# The --add-host line is what sends the gateway half to oab-relay.
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
    -e HTTPS_PROXY=http://oab-proxy:3128 \
    -e HTTP_PROXY=http://oab-proxy:3128 \
    -e NO_PROXY=localhost,127.0.0.1,oab-proxy,oab-broker \
    --add-host "gateway.discord.gg:$RELAY_IP" \
    -v "$SANDBOX/config/config.toml:/etc/openab/config.toml:ro" \
    -v "$SANDBOX/config/pi-coach:/home/node/bin/pi-coach:ro" \
    -v "$SANDBOX/config/adc-marker.json:/home/node/.config/gcloud/application_default_credentials.json:ro" \
    -v "$SANDBOX/vault:/workspace" \
    oab-sandbox:pi
