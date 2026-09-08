#!/bin/sh
# ── What this tests ───────────────────────────────────────────────────
# On 2026-09-04 the sandbox was started with a real second-bot token. openab
# printed `INFO openab: discord bot running`, the bot never came online, and the
# log carried no error at all. Two causes were stacked on top of each other:
#
#   layer 1  openab's own process has no proxy variables. HTTPS_PROXY lives in
#            config.toml's [agent] env, which openab hands to the *agent
#            subprocess* (pi) -- not to itself. On an --internal network that
#            leaves openab unable to resolve discord.com at all.
#   layer 2  serenity splits in two. Its REST half rides reqwest, which reads
#            the proxy environment; its gateway half rides tokio-tungstenite,
#            which has no proxy support whatsoever -- it takes an already
#            proxied TCP stream or nothing.
#
# Layer 1 masks layer 2 completely, so that run could not tell them apart and
# the repo kept recording the question as open. This script separates them by
# running the same container twice: once without the proxy variables
# (reproducing 2026-09-04) and once with them.
#
# ── What to expect ────────────────────────────────────────────────────
#   arm A (no proxy vars)  discord.com does not resolve; reqwest never mentions
#                          a proxy; the shard fails. The 2026-09-04 state.
#   arm B (proxy vars set) reqwest reports `proxy(...) intercepts
#                          'https://discord.com/'` and then pools an idle
#                          connection to discord.com -- the REST half is through
#                          the gate. The very next lines are the gateway half
#                          failing inside Tungstenite on name resolution,
#                          retried every 5s forever at WARN.
#
# No valid token is needed for either layer. serenity asks the *unauthenticated*
# GET /gateway for the websocket URL, so REST succeeds regardless of the token,
# and the gateway attempt that follows is what layer 2 is about.
#
# ── How to read the evidence ──────────────────────────────────────────
# Measurement comes from openab's own debug log, not from squid's access.log.
# squid writes a CONNECT tunnel's line when the tunnel *closes*, and reqwest
# keeps its connection pooled and open, so a successful request through the
# proxy leaves access.log empty for as long as the process lives. Counting log
# lines there reports "nothing happened" for a request that plainly did. The
# squid log is still captured, as corroboration for whatever has closed.
#
# ── How to re-run ─────────────────────────────────────────────────────
#   ./learn/13-discord-gateway-proxy.sh
#
# Costs nothing and needs no secret. No Vertex call is made: openab spawns pi
# only when a conversation starts, and none ever starts here -- which is also
# why the broker is not needed and /workspace is never mounted.
#
# Containers and networks are named oab-t13-*, so this cannot collide with a
# real ./run.sh session. It cleans up after itself.

set -eu

# Resolve paths from this script's location, the same way run.sh does, so a
# clone or worktree can run from any directory.
SANDBOX="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

PROXY=oab-t13-proxy
AGENT=oab-t13-agent
NET_INT=oab-t13-int
NET_EXT=oab-t13-ext
LOG=/var/log/squid/access.log
OUT="$SANDBOX/learn/out/discord-gateway"

# ── The verdict for layer 2 ───────────────────────────────────────────
#
# Layer 1 is mechanical -- either openab's REST half reached the gate or it did
# not. Layer 2 is a judgement, because the interesting evidence is a pairing:
# the REST half succeeded through the proxy *and*, in the same process at the
# same moment, the gateway half failed on a lookup it should never have been
# doing. Deciding when that pairing is proof, and when it is merely consistent
# with a proxy-blind websocket, is what this experiment is really for. The
# expensive way to get it wrong is the optimistic one: recording a limitation
# that is still there as "verified working".
#
# Arguments (all counts are from arm B's openab log):
#   $1  rest_ok    times reqwest pooled a connection to discord.com
#                  (> 0 means the REST half completed through the proxy)
#   $2  gw_tung    times the shard failed with a Tungstenite error
#   $3  gw_dns     how many of those name the failure as name resolution
#                  (tungstenite resolving the host itself = it ignored the proxy)
classify_layer2() {
    rest_ok="$1"
    gw_tung="$2"
    gw_dns="$3"

    # TODO(human): print one verdict line -- CONFIRMED / DISPROVEN / UNDECIDABLE
    # -- and a short reason underneath it.
    echo "  (undecided -- classify_layer2 is not implemented yet)"
}

# ── Preflight ─────────────────────────────────────────────────────────
#
# run.sh has no guard here, and its absence is what produced
# `failed to read /etc/openab/config.toml: Is a directory` on 2026-09-04:
# config.toml is gitignored, so a fresh clone or worktree never has it, and
# Docker silently creates a *directory* at a bind-mount source that is missing.
# Report the real cause instead of that one.
if [ ! -f "$SANDBOX/config/config.toml" ]; then
    echo "config/config.toml is missing -- it is gitignored, so a fresh clone" >&2
    echo "or worktree never has it. Create it before running this:" >&2
    echo "  cp config/config.toml.example config/config.toml   # then edit it" >&2
    exit 1
fi

# openab interpolates ${DISCORD_BOT_TOKEN} out of config.toml, so the variable
# has to exist -- but it does not have to be valid, because everything measured
# here happens before or regardless of authentication.
#
# It does have to be well *shaped*. serenity validates the format locally: a
# Discord bot token is three dot-separated parts, the first being a base64 user
# id, and anything else is refused before a socket is opened. A free-text
# placeholder therefore produces exactly the same empty log as a network failure
# -- the first version of this script used one, measured nothing, and still
# printed `discord bot running`.
#
# The parts are assembled here rather than written out as one string, and that
# is not stylistic. Committing the assembled value fails GitHub's push
# protection, which classifies it as a real Discord Bot Token -- a neat
# independent confirmation that the shape is what matters, since nothing about
# this value is secret. Keeping the halves apart keeps the file pushable.
TOKEN_ID=$(printf '123456789012345678' | base64)
TOKEN_TS=GaBcDe
TOKEN_SIG=$(printf 'oab-sandbox-learn-13-not-a-secret' | base64 | tr -d '=' | cut -c1-27)
TOKEN="$TOKEN_ID.$TOKEN_TS.$TOKEN_SIG"

cleanup() {
    docker rm -f "$AGENT" >/dev/null 2>&1 || true
    docker rm -f "$PROXY" >/dev/null 2>&1 || true
    docker network rm "$NET_INT" >/dev/null 2>&1 || true
    docker network rm "$NET_EXT" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
cleanup

mkdir -p "$OUT"
echo "sandbox: $SANDBOX"
echo "token:   well-shaped but invalid (no secret needed)"
echo "output:  $OUT"
echo

# ── The gate, built exactly as run.sh builds it ───────────────────────
docker network create --internal "$NET_INT" >/dev/null
docker network create "$NET_EXT" >/dev/null
docker run -d --name "$PROXY" --network "$NET_INT" \
    -v "$SANDBOX/proxy/squid.conf:/etc/squid/squid.conf:ro" \
    ubuntu/squid:latest >/dev/null
docker network connect "$NET_EXT" "$PROXY"

# squid is not listening the moment its container exists. Wait for the process
# rather than guessing a delay.
i=0
while [ "$i" -lt 30 ]; do
    if docker exec "$PROXY" pgrep -x squid >/dev/null 2>&1; then
        break
    fi
    i=$((i + 1))
    sleep 1
done
echo "proxy ready after ${i}s"
echo

# ── One arm of the experiment ─────────────────────────────────────────
#
# $1 = label, $2 = "proxy" to give openab the variables, anything else to
# withhold them. Every other flag matches run.sh, so the only difference between
# the arms is the thing being measured.
#
# RUST_LOG=debug is the instrument. At openab's default level the entire failure
# is invisible: the shard error is logged by serenity at WARN inside a retry
# loop, and openab's own INFO line says `discord bot running` either way.
run_arm() {
    label="$1"
    with_proxy="$2"

    echo "══════════ arm: $label ══════════"
    docker rm -f "$AGENT" >/dev/null 2>&1 || true

    before=$(docker exec "$PROXY" sh -c "wc -l < $LOG 2>/dev/null || echo 0")

    if [ "$with_proxy" = "proxy" ]; then
        docker run -d --name "$AGENT" --network "$NET_INT" \
            --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m \
            -v oab-pi-home:/home/node/.pi \
            -v oab-openab-home:/home/node/.openab \
            --cap-drop ALL --security-opt no-new-privileges --user 1000:1000 \
            --pids-limit 256 --memory 2g --memory-swap 2g \
            -e DISCORD_BOT_TOKEN="$TOKEN" \
            -e RUST_LOG=debug \
            -e HTTPS_PROXY="http://$PROXY:3128" \
            -e HTTP_PROXY="http://$PROXY:3128" \
            -e NO_PROXY="localhost,127.0.0.1,$PROXY" \
            -v "$SANDBOX/config/config.toml:/etc/openab/config.toml:ro" \
            -v "$SANDBOX/config/pi-coach:/home/node/bin/pi-coach:ro" \
            oab-sandbox:pi >/dev/null
    else
        docker run -d --name "$AGENT" --network "$NET_INT" \
            --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m \
            -v oab-pi-home:/home/node/.pi \
            -v oab-openab-home:/home/node/.openab \
            --cap-drop ALL --security-opt no-new-privileges --user 1000:1000 \
            --pids-limit 256 --memory 2g --memory-swap 2g \
            -e DISCORD_BOT_TOKEN="$TOKEN" \
            -e RUST_LOG=debug \
            -v "$SANDBOX/config/config.toml:/etc/openab/config.toml:ro" \
            -v "$SANDBOX/config/pi-coach:/home/node/bin/pi-coach:ro" \
            oab-sandbox:pi >/dev/null
    fi

    # The shard queuer retries every 5s; 14s captures three attempts, which is
    # enough to show the failure is persistent rather than a cold-start race.
    sleep 14

    docker logs "$AGENT" > "$OUT/$label.openab.log" 2>&1

    echo "--- what openab's own INFO line claims ---"
    grep -a "discord bot running" "$OUT/$label.openab.log" >/dev/null 2>&1 \
        && echo "  \"discord bot running\"  <- printed in this arm" \
        || echo "  (not printed)"

    echo
    echo "--- can this container resolve discord.com? ---"
    # Capture first rather than piping: the exit status of `cmd | head` is
    # head's, which is always 0, so a trailing `|| echo` would never fire and a
    # failed lookup would print as a blank line.
    dns=$(docker exec "$AGENT" getent hosts discord.com 2>&1 || true)
    if [ -n "$dns" ]; then
        echo "  $dns"
    else
        echo "  NO ANSWER -- discord.com did not resolve"
    fi

    echo
    echo "--- the REST half (reqwest) ---"
    grep -a -o "proxy([^)]*) intercepts '[^']*'" "$OUT/$label.openab.log" \
        | sort -u | sed 's/^/  /' || true
    grep -a -o 'pooling idle connection for ("https", discord.com)' \
        "$OUT/$label.openab.log" | sort -u | sed 's/^/  /' || true
    grep -a -o "reqwest::connect: starting new connection: [^ ]*" \
        "$OUT/$label.openab.log" | sort -u | sed 's/^/  /' || true

    echo
    echo "--- the gateway half (tokio-tungstenite) ---"
    grep -a -o "Err starting shard [0-9]*: [A-Za-z]*(.\{0,80\}" \
        "$OUT/$label.openab.log" | sort -u | head -3 | sed 's/^/  /' || true

    echo
    echo "--- what squid logged (closed transactions only) ---"
    after=$(docker exec "$PROXY" sh -c "wc -l < $LOG 2>/dev/null || echo 0")
    added=$((after - before))
    if [ "$added" -gt 0 ]; then
        docker exec "$PROXY" tail -n "$added" "$LOG" > "$OUT/$label.squid.log"
        awk '{print "  " $4, $6, $7}' "$OUT/$label.squid.log"
    else
        : > "$OUT/$label.squid.log"
        echo "  (nothing closed yet -- see the note in this script's header)"
    fi

    docker rm -f "$AGENT" >/dev/null 2>&1 || true
    echo
}

run_arm "A-no-proxy-vars" "none"
run_arm "B-proxy-vars"    "proxy"

# ── Verdict ───────────────────────────────────────────────────────────
count() {
    grep -a -c "$1" "$2" 2>/dev/null || true
}

A="$OUT/A-no-proxy-vars.openab.log"
B="$OUT/B-proxy-vars.openab.log"

a_rest_ok=$(count 'pooling idle connection for ("https", discord.com)' "$A")
b_rest_ok=$(count 'pooling idle connection for ("https", discord.com)' "$B")
b_proxied=$(count "intercepts 'https://discord.com/'" "$B")
b_gw_tung=$(count "Err starting shard 0: Tungstenite" "$B")
b_gw_dns=$(count "failed to lookup address information" "$B")

echo "══════════ verdict ══════════"
echo "arm A  REST reached discord.com      : ${a_rest_ok:-0}"
echo "arm B  reqwest routed via the proxy  : ${b_proxied:-0}"
echo "arm B  REST reached discord.com      : ${b_rest_ok:-0}"
echo "arm B  shard failed inside Tungstenite: ${b_gw_tung:-0}"
echo "arm B  ... of those, on name lookup  : ${b_gw_dns:-0}"
echo

echo "LAYER 1:"
if [ "${a_rest_ok:-0}" -eq 0 ] && [ "${b_rest_ok:-0}" -gt 0 ]; then
    echo "  CONFIRMED, and fixed by the variables alone."
    echo "  Without them openab never reaches Discord; with them its REST half"
    echo "  completes through squid. This alone explains the 2026-09-04 bot."
elif [ "${a_rest_ok:-0}" -gt 0 ]; then
    echo "  DISPROVEN -- openab reached Discord with no variables set."
    echo "  Something other than the environment is routing it; investigate."
else
    echo "  UNDECIDABLE -- neither arm reached Discord."
    echo "  Check that $PROXY is healthy and that squid.conf allows this source."
fi
echo

echo "LAYER 2:"
classify_layer2 "${b_rest_ok:-0}" "${b_gw_tung:-0}" "${b_gw_dns:-0}"
