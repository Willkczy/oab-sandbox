#!/bin/sh
# Experiment: what exactly does that sed in AGENTS.md cut away?
#
# What it tests  : which parts of a fetched problem page sed '/^Topics$/,$d'
#                  removes
# What to expect : straight after Topics come the pattern classification, the
#                  complexity hints, and Hint 1/2/3 -- every one of them
#                  something the coaching rules explicitly forbid revealing early
# Why it matters : this is the only place in the entire system where an external
#                  web page enters the context, and therefore the only
#                  prompt-injection entry point
# Re-run         : ./learn/07-context-truncation.sh [problem url]
#
# Note: this makes one request to r.jina.ai (no key needed, rate limited to 20
# requests per 60 seconds).

set -e
URL="${1:-https://neetcode.io/problems/buy-and-sell-crypto/question?list=neetcode150}"

RAW=$(mktemp)
trap 'rm -f "$RAW"' EXIT

echo "fetching: $URL"
curl -s --max-time 60 "https://r.jina.ai/$URL" > "$RAW"

full=$(wc -l < "$RAW" | tr -d ' ')
kept=$(sed '/^Topics$/,$d' "$RAW" | wc -l | tr -d ' ')

echo
echo "=== Size ==="
printf "  raw page        %4s lines\n" "$full"
printf "  after sed       %4s lines   (%s lines cut)\n" "$kept" "$((full - kept))"

echo
echo "=== Tail of what survives (the last lines that reach the context) ==="
sed '/^Topics$/,$d' "$RAW" | tail -6 | sed 's/^/  │ /'

echo
echo "=== What gets cut (never reaches the context at all) ==="
sed -n '/^Topics$/,$p' "$RAW" | head -24 | sed 's/^/  ✂ /'
