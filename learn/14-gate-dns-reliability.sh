#!/bin/sh
# ── What this tests ───────────────────────────────────────────────────
# A sandbox left running for 16 hours on 2026-09-15 kept losing the Discord
# gateway. squid answered 236 gateway CONNECTs with `TCP_TUNNEL/503`, and 215 of
# those never reached an address at all:
#
#   172.20.0.3 TCP_TUNNEL/503 0 CONNECT gateway.discord.gg:443 - HIER_NONE/- -
#
# `HIER_NONE` means squid never picked a peer, so it failed while resolving the
# name, and a minute later the same lookup worked. Whatever it is, it is not the
# relay: the relay had already handed squid a perfectly good CONNECT.
#
# Two arms, because the fault is intermittent and a laptop is a bad place to
# watch one:
#
#   watch   sample the gate and its resolver on an interval, and report rates
#   outage  take squid's resolver away on purpose, give it back, and measure how
#           long squid keeps failing on its own recollection afterwards
#
# The sampler sits where squid sits: on the internal network and on the external
# one. That is not a detail. A container attached only to the internal network
# cannot resolve any external name at all, which is the whole reason the agent
# needs the relay, so sampling from there measures the sandbox's design rather
# than the fault. The first version of this script did exactly that and reported
# every lookup as a failure.
#
# ── What the first runs settled ───────────────────────────────────────
# IPv6 was the original suspicion: squid opens a DNS socket at `[::]` and asks
# for both records. It is ruled out. Every AAAA lookup fails in about a
# millisecond, in every round, because gateway.discord.gg publishes no IPv6
# address at all -- `dig AAAA gateway.discord.gg` returns nothing. A constant
# cannot explain an intermittent failure.
#
# ── What to expect ────────────────────────────────────────────────────
#   watch    on a healthy machine: A=ok, AAAA=FAIL, GATE=ok in every round. The
#            2026-09-15 failures came in bursts about an hour apart, so a short
#            quiet window proves nothing. Run it for half an hour, on the machine
#            that actually runs the sandbox.
#   outage   while the resolver is gone, squid logs HIER_NONE, the 2026-09-15
#            shape. What the arm measures is the delay after the resolver comes
#            back: with the default, squid should keep failing for up to a minute
#            on a failure it remembers; with the directive, for about a second.
#
# ── How to re-run ─────────────────────────────────────────────────────
#   ./learn/14-gate-dns-reliability.sh watch [seconds] [interval]
#   ./learn/14-gate-dns-reliability.sh outage
#
# `watch` defaults to 120 seconds at 5-second intervals, a smoke test.
#
# Costs nothing and needs no secret: each CONNECT is opened and closed without a
# token, and no Vertex call happens. Containers and networks are named oab-t14-*,
# so this cannot collide with a running ./run.sh. It cleans up after itself.

set -eu

SANDBOX="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
MODE="${1:-watch}"
case "$MODE" in
    watch | outage) ;;
    *) echo "usage: $0 [watch [seconds] [interval] | outage]" >&2; exit 2 ;;
esac
SECONDS_TOTAL="${2:-120}"
INTERVAL="${3:-5}"

PROXY=oab-t14-proxy
SAMPLER=oab-t14-sampler
FORWARDER=oab-t14-dns
NET_INT=oab-t14-int
NET_EXT=oab-t14-ext
# The outage arm needs the resolver's address to be the same before and after it
# is restarted, so the internal network gets a subnet and the forwarder a fixed
# address inside it. A reassigned address would look exactly like a failure that
# never recovers.
INT_SUBNET=10.77.0.0/24
DNS_IP=10.77.0.53
HOST=gateway.discord.gg
OUT="$SANDBOX/learn/out/gate-dns"

cleanup() {
    docker rm -f "$SAMPLER" >/dev/null 2>&1 || true
    docker rm -f "$FORWARDER" >/dev/null 2>&1 || true
    docker rm -f "$PROXY" >/dev/null 2>&1 || true
    docker network rm "$NET_INT" >/dev/null 2>&1 || true
    docker network rm "$NET_EXT" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
cleanup

mkdir -p "$OUT"

# Each round prints one line: epoch, wall clock, then each check's verdict and
# how long it took. A lookup that takes seconds is as interesting as one that
# fails, because that is what a resolver dropping a query looks like.
LOOP='
end=$(( $(date +%s) + SECONDS_TOTAL ))
while [ "$(date +%s)" -lt "$end" ]; do
    line="$(date +%s) $(date +%H:%M:%S)"
    for check in A AAAA GATE; do
        t0=$(date +%s%3N)
        case "$check" in
            A)    getent ahostsv4 "$HOST" >/dev/null 2>&1 ;;
            AAAA) getent ahostsv6 "$HOST" >/dev/null 2>&1 ;;
            GATE) socat -T 8 STDIO "PROXY:$PROXY:$HOST:443,proxyport=3128" </dev/null >/dev/null 2>&1 ;;
        esac
        if [ $? -eq 0 ]; then verdict=ok; else verdict=FAIL; fi
        t1=$(date +%s%3N)
        line="$line $check=$verdict/$((t1 - t0))ms"
    done
    echo "$line"
    sleep "$INTERVAL"
done
'

start_proxy() {   # start_proxy <squid.conf>
    docker rm -f "$PROXY" >/dev/null 2>&1 || true
    docker run -d --name "$PROXY" --network "$NET_INT" \
        -v "$1:/etc/squid/squid.conf:ro" \
        ubuntu/squid:latest >/dev/null
    docker network connect "$NET_EXT" "$PROXY"
    i=0
    while [ "$i" -lt 30 ]; do
        if docker exec "$PROXY" pgrep -x squid >/dev/null 2>&1; then break; fi
        i=$((i + 1))
        sleep 1
    done
    sleep 2
}

# The agent image is used for the sampler because it carries both getent and
# socat. Nothing else about it matters here; no agent is started.
start_sampler() {   # start_sampler <seconds> <interval>
    docker rm -f "$SAMPLER" >/dev/null 2>&1 || true
    docker run -d --name "$SAMPLER" --network "$NET_INT" --network "$NET_EXT" \
        --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m \
        --cap-drop ALL --security-opt no-new-privileges --user 1000:1000 \
        --pids-limit 64 --memory 256m --memory-swap 256m \
        -e "HOST=$HOST" -e "PROXY=$PROXY" \
        -e "SECONDS_TOTAL=$1" -e "INTERVAL=$2" \
        --entrypoint sh oab-sandbox:pi -c "$LOOP" >/dev/null
}

wait_for_sampler() {   # wait_for_sampler <seconds>
    waited=0
    while [ "$waited" -lt "$1" ]; do
        if [ "$(docker inspect -f '{{.State.Running}}' "$SAMPLER")" != "true" ]; then return 0; fi
        sleep 2
        waited=$((waited + 2))
    done
}

docker network create --internal --subnet "$INT_SUBNET" "$NET_INT" >/dev/null
docker network create "$NET_EXT" >/dev/null

# ══════════════════════════════════════════════════════════════════════
if [ "$MODE" = watch ]; then
    echo "sampling $HOST for ${SECONDS_TOTAL}s every ${INTERVAL}s"
    echo "output:  $OUT"
    echo
    start_proxy "$SANDBOX/proxy/squid.conf"
    start_sampler "$SECONDS_TOTAL" "$INTERVAL"
    wait_for_sampler $((SECONDS_TOTAL + INTERVAL + 30))

    docker logs "$SAMPLER" > "$OUT/samples.txt" 2>&1
    docker exec "$PROXY" cat /var/log/squid/access.log > "$OUT/squid.log" 2>/dev/null || true

    # The space before A= is load-bearing: `A=FAIL` also matches inside
    # `AAAA=FAIL`, and the first version of this script reported every IPv6
    # failure as an IPv4 one.
    rounds=$(grep -c ' A=' "$OUT/samples.txt" || true)
    a_fail=$(grep -c ' A=FAIL' "$OUT/samples.txt" || true)
    aaaa_fail=$(grep -c ' AAAA=FAIL' "$OUT/samples.txt" || true)
    aaaa_ok=$(grep -c ' AAAA=ok' "$OUT/samples.txt" || true)
    gate_fail=$(grep -c 'GATE=FAIL' "$OUT/samples.txt" || true)
    slow=$(grep -c -E '=(ok|FAIL)/[0-9]{4,}ms' "$OUT/samples.txt" || true)

    echo "══════════ samples ══════════"
    head -3 "$OUT/samples.txt" | sed 's/^/  /'
    [ "$rounds" -le 3 ] || echo "  ..."
    [ "$rounds" -le 3 ] || tail -2 "$OUT/samples.txt" | sed 's/^/  /'

    echo
    echo "rounds                        : $rounds"
    echo "IPv4 lookups failed           : $a_fail"
    echo "IPv6 lookups failed           : $aaaa_fail (succeeded $aaaa_ok)"
    echo "CONNECTs through squid failed : $gate_fail"
    echo "checks that took over a second: $slow"

    echo
    echo "══════════ what squid logged ══════════"
    awk '{ split($4, a, "/"); print "  " a[1] "/" a[2], $9 }' "$OUT/squid.log" | sort | uniq -c | sort -rn

    echo
    echo "══════════ verdict ══════════"
    if [ "$rounds" -gt 0 ] && [ "$a_fail" -eq "$rounds" ]; then
        echo "  THE PROBE IS STANDING IN THE WRONG PLACE -- every IPv4 lookup failed."
        echo "  A sampler that cannot resolve anything is not where squid is. Check"
        echo "  that it is attached to $NET_EXT as well as $NET_INT."
    elif [ "$gate_fail" -eq 0 ] && [ "$a_fail" -eq 0 ] && [ "$slow" -eq 0 ] && [ "$aaaa_ok" -eq 0 ]; then
        echo "  NOTHING REPRODUCED in this window, and the AAAA failures are the"
        echo "  expected ones: the name has no IPv6 address. The 2026-09-15 bursts"
        echo "  were about an hour apart, so this is only evidence if the window was"
        echo "  long. Re-run with 1800 or more, where the sandbox really runs."
    elif [ "$aaaa_ok" -gt 0 ] && [ "$aaaa_fail" -gt 0 ] && [ "$a_fail" -eq 0 ]; then
        echo "  IPv6 LOOKUPS ARE THE ODD ONE OUT -- $aaaa_fail of $rounds failed while"
        echo "  every IPv4 lookup succeeded, and the same lookup worked in other"
        echo "  rounds. squid asks for both, so that is worth pursuing."
    elif [ "$gate_fail" -gt 0 ]; then
        echo "  THE GATE FAILED $gate_fail TIME(S) out of $rounds."
        echo "  In $OUT/squid.log, HIER_NONE means the lookup failed and an address"
        echo "  after HIER_DIRECT means the connection did. They are different faults."
    else
        echo "  MIXED -- read $OUT/samples.txt before concluding anything."
    fi
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════
# outage: take squid's resolver away, give it back, and time the recovery.
#
# The first version of this arm disconnected the proxy from the external network.
# That was the wrong outage: squid kept resolving from its cache and logged
# `TCP_TUNNEL/503 HIER_DIRECT/<address>`, a connection that failed, while the
# 2026-09-15 bursts were `HIER_NONE`, a lookup that failed. It also recovered the
# instant the network came back, which answered a question nobody had asked.
#
# What those bursts looked like is the clue this arm follows: each failure took
# between 0 and 11 milliseconds. Nothing resolves a name that fast and fails; that
# is the shape of squid answering from memory. squid keeps a failed lookup for
# `negative_dns_ttl`, 60 seconds by default, and the client retried every 5
# seconds, which turns one real failure into a dozen instant ones.
#
# So squid is pointed at a resolver this script controls -- socat forwarding UDP
# 53 to a public one -- and the outage is that forwarder stopping. Arm A is
# squid.conf as it stands; arm B adds one directive:
#
#   negative_dns_ttl 1 second
#
# Both arms lose the resolver for the same 30 seconds. What differs afterwards is
# only how long squid keeps refusing on its own recollection.
CONF_A="$OUT/squid-as-is.conf"
CONF_B="$OUT/squid-fast-retry.conf"
grep -v -E '^(negative_dns_ttl|positive_dns_ttl|dns_timeout|dns_nameservers)' "$SANDBOX/proxy/squid.conf" > "$CONF_A"
# Three settings both arms share, so that the only difference between them is the
# one being measured.
#
# dns_nameservers    a resolver this experiment can switch off.
# positive_dns_ttl   squid remembers a *successful* lookup for six hours by
#                    default, so a resolver that vanishes for thirty seconds
#                    changes nothing at all -- measured, 14 CONNECTs in a row
#                    succeeded through an outage. Five seconds forces squid to
#                    ask again inside the window, which is the case that hurt on
#                    2026-09-15: an entry that had expired and could not be
#                    refreshed.
# dns_timeout        30 seconds by default, which would swamp a 30-second outage.
printf '\n# added by learn/14\ndns_nameservers %s\npositive_dns_ttl 5 seconds\ndns_timeout 5 seconds\n' "$DNS_IP" >> "$CONF_A"
cp "$CONF_A" "$CONF_B"
printf '\n# added by learn/14 to measure what the default costs\nnegative_dns_ttl 1 second\n' >> "$CONF_B"

# 1.1.1.1 is the upstream only because the experiment needs one that is not
# Docker's, so that stopping this container is the whole outage.
start_forwarder() {
    docker rm -f "$FORWARDER" >/dev/null 2>&1 || true
    docker run -d --name "$FORWARDER" --network "$NET_INT" --ip "$DNS_IP" \
        --read-only --cap-drop ALL --security-opt no-new-privileges --user 1000:1000 \
        --pids-limit 64 --memory 32m --memory-swap 32m \
        oab-relay:latest -d UDP4-RECVFROM:53,fork,reuseaddr UDP4-SENDTO:1.1.1.1:53 >/dev/null
    docker network connect "$NET_EXT" "$FORWARDER"
    sleep 2
}

run_outage() {   # run_outage <label> <conf>
    label="$1"
    echo "── arm $label ──"
    start_forwarder
    start_proxy "$2"
    start_sampler 150 2
    sleep 12   # a baseline with the gate healthy

    docker stop -t 0 "$FORWARDER" >/dev/null
    down=$(date +%s)
    sleep 30   # the outage: squid's resolver is gone

    docker start "$FORWARDER" >/dev/null
    up=$(date +%s)
    sleep 75   # long enough for a 60-second negative cache to expire

    # Read the log before removing the container. Removing it first leaves an
    # empty file, and an empty file reads as "nothing ever failed and nothing
    # ever recovered" -- a clean-looking answer to a question never asked.
    docker logs "$SAMPLER" > "$OUT/outage-$label.txt" 2>&1 || true
    docker exec "$PROXY" cat /var/log/squid/access.log > "$OUT/squid-$label.log" 2>/dev/null || true
    docker rm -f "$SAMPLER" >/dev/null 2>&1 || true

    cut_fail=$(awk -v a="$down" -v b="$up" '$1 >= a && $1 <= b && /GATE=FAIL/ { n++ } END { print n + 0 }' "$OUT/outage-$label.txt")
    cut_dns=$(awk -v a="$down" -v b="$up" '$1 >= a && $1 <= b && / A=FAIL/ { n++ } END { print n + 0 }' "$OUT/outage-$label.txt")
    recovery=$(awk -v t="$up" '$1 >= t && /GATE=ok/ { print $1 - t; exit }' "$OUT/outage-$label.txt")
    rounds=$(grep -c ' A=' "$OUT/outage-$label.txt" || true)
    if [ -z "$recovery" ]; then
        recovery=never
        shown=never
    else
        shown="${recovery}s"
    fi

    echo "  rounds sampled: $rounds"
    echo "  while cut off:  $cut_fail CONNECT(s) failed, $cut_dns lookup(s) failed"
    echo "  back after:     $shown"
    # What squid made of it. HIER_NONE is a lookup that failed; an address after
    # HIER_DIRECT is a connection that failed. The 2026-09-15 bursts were the
    # first kind, so an arm that only produces the second has not reproduced them.
    echo "  squid logged while cut off:"
    awk -v a="$down" -v b="$up" '$1 >= a && $1 <= b { split($4, r, "/"); print "    " r[1] "/" r[2], $9 }' \
        "$OUT/squid-$label.log" | sort | uniq -c | sort -rn
    printf '%s\n' "$recovery" > "$OUT/recovery-$label.txt"
}

echo "outage arm: cutting the gate off for 30s, twice"
echo "output: $OUT"
echo
run_outage as-is "$CONF_A"
echo
run_outage fast-retry "$CONF_B"

a=$(cat "$OUT/recovery-as-is.txt")
b=$(cat "$OUT/recovery-fast-retry.txt")

echo
echo "══════════ verdict ══════════"
echo "  recovery with squid.conf as it stands  : $a"
echo "  recovery with negative_dns_ttl 1 second: $b"
echo
case "$a" in
    never) echo "  arm A never recovered inside the window, which is worse than the"
           echo "  default explains. Read $OUT/outage-as-is.txt and check that the"
           echo "  sampler recorded any rounds at all before believing it." ;;
    *)
        case "$b" in
            never) echo "  arm B never recovered, so the directive is not the answer." ;;
            *)
                if [ "$a" -ge $((b + 10)) ]; then
                    echo "  THE NEGATIVE DNS CACHE IS THE AMPLIFIER. The connection came back at"
                    echo "  the same moment in both arms; only the remembered failure differed."
                    echo "  Adding the directive to proxy/squid.conf shortens every outage that"
                    echo "  starts with a failed lookup, including the ones after a machine wakes."
                else
                    echo "  NO MEANINGFUL DIFFERENCE. The delay is not squid remembering the"
                    echo "  failure, so look at what the gate does with the connection itself."
                fi
                ;;
        esac
        ;;
esac
