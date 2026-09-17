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
#   export DISCORD_BOT_TOKEN=<a token no other instance is using>
#   ./run.sh
#
# On a machine you also use, this is not a long-running service: run ./stop.sh
# when finished. On the machine that hosts it permanently,
# deploy/install-service.sh runs it under launchd instead, and ./stop.sh there
# only stops it until launchd starts it again.

set -e

# Resolve mounts from this script's location, so a clone or worktree can run
# from any directory instead of requiring ~/Projects/oab-sandbox.
SANDBOX="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

if [ -z "$DISCORD_BOT_TOKEN" ]; then
    echo "DISCORD_BOT_TOKEN is not set. It must be a token no other instance is" >&2
    echo "using: two instances on one token answer every message twice." >&2
    exit 1
fi

# --- Is the vault the coach reads the one you have been practising in? ---
#
# vault/ is a clone, and nothing updates it on its own. On 2026-09-16 it turned
# out to be four weeks behind the main vault, and the coach had been answering
# from that snapshot without a word. This only reports; ./vault-sync.sh syncs.
"$SANDBOX/vault-sync.sh" remind-start || true

# --- Networks: oab-int is --internal (no route out); only oab-ext has one ---
docker network inspect oab-int >/dev/null 2>&1 || docker network create --internal oab-int
docker network inspect oab-ext >/dev/null 2>&1 || docker network create oab-ext

# --- Long-lived services: reuse only what still matches ---
#
# oab-proxy, oab-relay and oab-broker outlive a single agent run, so a second
# ./run.sh keeps them rather than restarting them. The test used to be only "is a
# container with this name running?". On 2026-09-15 it said yes for a squid
# started from an older squid.conf. squid reads its configuration once, at start,
# so the new allowlist never took effect, and the Discord bot stayed offline with
# nothing in openab's log (finding 8).
#
# Each service is now started with a label that fingerprints what it was started
# from: the image ID, every docker run argument, and the contents of the config
# file it mounts, if any. A running container is reused only when its label
# matches what this run would start. Anything else is recreated, and says so.
#
# The fingerprint is a cksum, a change detector and nothing more. The broker's key
# file is deliberately left out of it: a label is readable by anyone who can run
# `docker inspect`, and not even a checksum of a private key belongs there. A
# rotated key therefore still needs ./stop.sh first.
#
# learn/dev/03 runs this function against a throwaway container.
#
# start_service <name> <image> <config file, or -> <docker run arguments...>
# The arguments must include the image. Returns 0 if it started a container, 1 if
# it reused a running one.
start_service() {
    name=$1
    image=$2
    config=$3
    shift 3

    want=$(
        {
            docker image inspect -f '{{.Id}}' "$image" 2>/dev/null
            if [ "$config" != "-" ]; then cat "$config"; fi
            printf '%s\n' "$@"
        } | cksum | awk '{ print $1 "-" $2 }'
    )
    running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)
    have=$(docker inspect -f '{{index .Config.Labels "oab.inputs"}}' "$name" 2>/dev/null || true)

    if [ "$running" = "true" ] && [ "$have" = "$want" ]; then
        return 1
    fi
    if [ "$running" = "true" ]; then
        echo "$name is running, but not from what this run would start -- recreating it"
    fi
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --label "oab.inputs=$want" "$@" >/dev/null
    return 0
}

# --- Egress gateway ---
if start_service oab-proxy ubuntu/squid:latest "$SANDBOX/proxy/squid.conf" \
    --network oab-int \
    -v "$SANDBOX/proxy/squid.conf:/etc/squid/squid.conf:ro" \
    ubuntu/squid:latest; then
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
if start_service oab-relay oab-relay:latest - \
    --network oab-int \
    --read-only \
    --cap-drop ALL --security-opt no-new-privileges --user 1000:1000 \
    --pids-limit 32 --memory 32m --memory-swap 32m \
    oab-relay:latest -d -d TCP-LISTEN:443,fork,reuseaddr \
    PROXY:oab-proxy:gateway.discord.gg:443,proxyport=3128; then
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
if start_service oab-broker oab-broker:latest - \
    --network oab-int \
    --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m \
    --cap-drop ALL --security-opt no-new-privileges --user 1000:1000 \
    --pids-limit 64 --memory 256m --memory-swap 256m \
    -e HTTPS_PROXY=http://oab-proxy:3128 \
    -e NO_PROXY=localhost,127.0.0.1,oab-proxy \
    -v "$HOME/.config/openab/sa-key.json:/run/secrets/sa-key.json:ro" \
    oab-broker:latest; then
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
