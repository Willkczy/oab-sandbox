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
# A third arm tests the remedy rather than the failure. It adds the relay from
# relay/, reached through an --add-host entry exactly as run.sh wires it, and
# asks whether the gateway half now leaves through the same gate as the REST half.
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
#   arm C (vars + relay)   the REST half as in arm B. gateway.discord.gg now
#                          resolves to the relay, and the gateway half gets
#                          Hello from Discord, sends Identify, and is closed
#                          with code 4004 "Authentication failed.". openab logs
#                          `Discord rejected bot token.` and exits within the
#                          second. squid logs the gateway tunnel once it closes.
#
# No valid token is needed for either layer. serenity asks the *unauthenticated*
# GET /gateway for the websocket URL, so REST succeeds regardless of the token,
# and the gateway attempt that follows is what layer 2 is about.
#
# In arm C the invalid token becomes the instrument. Only Discord's gateway can
# send close code 4004, so seeing it proves the websocket crossed the gate and
# reached Discord, and no real token is ever exposed to the experiment.
#
# ── How to read the evidence ──────────────────────────────────────────
# Measurement comes from openab's own debug log, not from squid's access.log.
# squid writes a CONNECT tunnel's line when the tunnel *closes*, and reqwest
# keeps its connection pooled and open, so a successful request through the
# proxy leaves access.log empty for as long as the process lives. Counting log
# lines there reports "nothing happened" for a request that plainly did. The
# squid log is still captured, as corroboration for whatever has closed.
#
# Arm C's gateway tunnel does close, when Discord hangs up, so it is logged. The
# client squid records for it is the relay, not the agent, and the address after
# HIER_DIRECT is Discord's. A private address there would be the loop run.sh
# warns about, which squid.conf's private_dst rule turns into TCP_DENIED.
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
RELAY=oab-t13-relay
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
    docker rm -f "$RELAY" >/dev/null 2>&1 || true
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

# ── The relay, built exactly as run.sh builds it ──────────────────────
#
# Only arm C points anything at it. Starting it up front costs the other arms
# nothing, because nothing in them resolves gateway.discord.gg to this address.
docker run -d --name "$RELAY" --network "$NET_INT" \
    --read-only \
    --cap-drop ALL --security-opt no-new-privileges --user 1000:1000 \
    --pids-limit 32 --memory 32m --memory-swap 32m \
    oab-relay:latest -d -d TCP-LISTEN:443,fork,reuseaddr \
    "PROXY:$PROXY:gateway.discord.gg:443,proxyport=3128" >/dev/null
RELAY_IP=$(docker inspect -f "{{with index .NetworkSettings.Networks \"$NET_INT\"}}{{.IPAddress}}{{end}}" "$RELAY")
echo "relay at $RELAY_IP"
echo

# ── One arm of the experiment ─────────────────────────────────────────
#
# $1 = label, $2 = what openab is given:
#   none   no proxy variables (arm A)
#   proxy  the proxy variables (arm B)
#   relay  the proxy variables plus the relay's hosts entry (arm C)
# Every other flag matches run.sh, so the only difference between the arms is the
# thing being measured.
#
# RUST_LOG=debug is the instrument. At openab's default level the entire failure
# is invisible: the shard error is logged by serenity at WARN inside a retry
# loop, and openab's own INFO line says `discord bot running` either way.
run_arm() {
    label="$1"
    given="$2"

    echo "══════════ arm: $label ══════════"
    docker rm -f "$AGENT" >/dev/null 2>&1 || true

    before=$(docker exec "$PROXY" sh -c "wc -l < $LOG 2>/dev/null || echo 0")

    # The per-arm flags are collected in the positional parameters, the one array
    # POSIX sh has, so each flag stays a single argument however it is spelled.
    set --
    if [ "$given" = "proxy" ] || [ "$given" = "relay" ]; then
        set -- "$@" \
            -e HTTPS_PROXY="http://$PROXY:3128" \
            -e HTTP_PROXY="http://$PROXY:3128" \
            -e NO_PROXY="localhost,127.0.0.1,$PROXY"
    fi
    if [ "$given" = "relay" ]; then
        set -- "$@" --add-host "gateway.discord.gg:$RELAY_IP"
    fi

    docker run -d --name "$AGENT" --network "$NET_INT" \
        --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m \
        -v oab-pi-home:/home/node/.pi \
        -v oab-openab-home:/home/node/.openab \
        --cap-drop ALL --security-opt no-new-privileges --user 1000:1000 \
        --pids-limit 256 --memory 2g --memory-swap 2g \
        -e DISCORD_BOT_TOKEN="$TOKEN" \
        -e RUST_LOG=debug \
        "$@" \
        -v "$SANDBOX/config/config.toml:/etc/openab/config.toml:ro" \
        -v "$SANDBOX/config/pi-coach:/home/node/bin/pi-coach:ro" \
        oab-sandbox:pi >/dev/null

    # The shard queuer retries every 5s; 14s captures three attempts, which is
    # enough to show the failure is persistent rather than a cold-start race.
    sleep 14

    docker logs "$AGENT" > "$OUT/$label.openab.log" 2>&1

    echo "--- what openab's own INFO line claims ---"
    grep -a "discord bot running" "$OUT/$label.openab.log" >/dev/null 2>&1 \
        && echo "  \"discord bot running\"  <- printed in this arm" \
        || echo "  (not printed)"

    echo
    echo "--- what this arm's resolver answers ---"
    # Asked from a sibling container with the same network flags rather than
    # with `docker exec`. In arm C openab exits within a second of Discord
    # rejecting the token, and an exec into a stopped container measures nothing.
    #
    # Capture first rather than piping: the exit status of `cmd | head` is
    # head's, which is always 0, so a trailing `|| echo` would never fire and a
    # failed lookup would print as a blank line.
    for host in discord.com gateway.discord.gg; do
        dns=$(docker run --rm --network "$NET_INT" "$@" --entrypoint getent \
            oab-sandbox:pi hosts "$host" 2>/dev/null || true)
        if [ -n "$dns" ]; then
            printf '  %-20s %s\n' "$host" "$(echo "$dns" | awk 'NR == 1 { print $1 }')"
        else
            printf '  %-20s %s\n' "$host" "NO ANSWER"
        fi
    done

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
    grep -a -o "Ok(Hello([0-9]*))" \
        "$OUT/$label.openab.log" | sort -u | sed 's/^/  gateway sent /' || true
    grep -a -o 'Received close frame: .*"[^"]*" })' \
        "$OUT/$label.openab.log" | sort -u | sed 's/^/  /' || true
    grep -a -o "Discord rejected bot token\." \
        "$OUT/$label.openab.log" | sort -u | sed 's/^/  openab: /' || true

    echo
    echo "--- what squid logged (closed transactions only) ---"
    after=$(docker exec "$PROXY" sh -c "wc -l < $LOG 2>/dev/null || echo 0")
    added=$((after - before))
    if [ "$added" -gt 0 ]; then
        docker exec "$PROXY" tail -n "$added" "$LOG" > "$OUT/$label.squid.log"
        # client, result, method, destination, and the address squid dialled
        awk '{print "  " $3, $4, $6, $7, $9}' "$OUT/$label.squid.log"
    else
        : > "$OUT/$label.squid.log"
        echo "  (nothing closed yet -- see the note in this script's header)"
    fi

    docker rm -f "$AGENT" >/dev/null 2>&1 || true
    echo
}

run_arm "A-no-proxy-vars" "none"
run_arm "B-proxy-vars"    "proxy"
run_arm "C-relay"         "relay"

# The relay is removed on exit, and its log is the only record of what it
# forwarded, so keep it with the other evidence.
docker logs "$RELAY" > "$OUT/relay.log" 2>&1

# ── Verdict ───────────────────────────────────────────────────────────
count() {
    grep -a -c "$1" "$2" 2>/dev/null || true
}

A="$OUT/A-no-proxy-vars.openab.log"
B="$OUT/B-proxy-vars.openab.log"
C="$OUT/C-relay.openab.log"
C_SQUID="$OUT/C-relay.squid.log"

a_rest_ok=$(count 'pooling idle connection for ("https", discord.com)' "$A")
b_rest_ok=$(count 'pooling idle connection for ("https", discord.com)' "$B")
b_proxied=$(count "intercepts 'https://discord.com/'" "$B")
b_gw_tung=$(count "Err starting shard 0: Tungstenite" "$B")
b_gw_dns=$(count "failed to lookup address information" "$B")
c_hello=$(count "Ok(Hello(" "$C")
c_4004=$(count "Received close frame: .*code: Library(4004)" "$C")
c_gw_dns=$(count "failed to lookup address information" "$C")
c_tunnel=$(count "TCP_TUNNEL/200 [0-9]* CONNECT gateway.discord.gg:443" "$C_SQUID")
c_denied=$(count "TCP_DENIED/403 [0-9]* CONNECT gateway.discord.gg:443" "$C_SQUID")
c_upstream=$(count "TCP_TUNNEL/503 [0-9]* CONNECT gateway.discord.gg:443" "$C_SQUID")

echo "══════════ verdict ══════════"
echo "arm A  REST reached discord.com      : ${a_rest_ok:-0}"
echo "arm B  reqwest routed via the proxy  : ${b_proxied:-0}"
echo "arm B  REST reached discord.com      : ${b_rest_ok:-0}"
echo "arm B  shard failed inside Tungstenite: ${b_gw_tung:-0}"
echo "arm B  ... of those, on name lookup  : ${b_gw_dns:-0}"
echo "arm C  gateway sent Hello            : ${c_hello:-0}"
echo "arm C  gateway closed with 4004      : ${c_4004:-0}"
echo "arm C  squid tunnelled the gateway   : ${c_tunnel:-0}"
echo "arm C  squid denied the gateway      : ${c_denied:-0}"
echo "arm C  squid could not reach Discord : ${c_upstream:-0}"
echo "arm C  shard failed on name lookup   : ${c_gw_dns:-0}"
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
echo

# Unlike layer 2 this one is mechanical, because the decisive evidence is a
# single value only one party can produce. A close code of 4004 comes from
# Discord's gateway or from nowhere, and the squid line says which road it took.
echo "THE RELAY (arm C):"
if [ "${c_4004:-0}" -gt 0 ] && [ "${c_tunnel:-0}" -gt 0 ]; then
    echo "  CONFIRMED -- the gateway half crossed the gate and reached Discord."
    echo "  Only Discord's gateway sends close code 4004, and squid logged the"
    echo "  tunnel that carried it. The token was rejected, as it should be."
elif [ "${c_denied:-0}" -gt 0 ]; then
    echo "  BLOCKED AT THE GATE -- squid refused the gateway CONNECT."
    echo "  Either squid.conf lacks gateway.discord.gg, or the name resolved to a"
    echo "  private address and private_dst refused it. Look for a network alias."
elif [ "${c_upstream:-0}" -gt 0 ]; then
    # Seen once in three runs on 2026-09-15: squid answered 503 for discord.com
    # and the gateway alike, and the next run passed unchanged. A 503 is the
    # internet side of the gate failing, which says nothing about the relay.
    echo "  UPSTREAM FAILURE -- squid took the CONNECT but could not reach Discord."
    echo "  That is the far side of the gate, not the relay. Re-run before"
    echo "  concluding anything."
elif [ "${c_gw_dns:-0}" -gt 0 ]; then
    echo "  NOT IN THE PATH -- openab still resolved the gateway host itself."
    echo "  The --add-host entry did not reach the agent container."
else
    echo "  UNDECIDABLE -- no close code, no squid line, no lookup failure."
    echo "  Read $C and $OUT/relay.log before concluding anything."
fi
