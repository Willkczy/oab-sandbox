#!/bin/sh
# Experiment: an LLM has no memory, so every turn resends the entire history.
#
# What it tests  : how input tokens and output tokens trend across a real
#                  conversation
# What to expect : input climbs monotonically, because everything is resent each
#                  time; output shows no trend at all
# Data source    : real records from ~/.pi/agent/sessions/ -- only the usage
#                  fields are read, never the conversation content
# Re-run         : ./learn/05-context-growth.sh [sessions dir]
#
# Pass a directory as an argument to look at a different vault's records.

set -e
cd "$(dirname "$0")/.."

# With no argument, pick whichever directory under ~/.pi/agent/sessions/ was
# active most recently. (This used to hardcode the author's own vault path,
# which meant a fresh clone found nothing.)
SESSIONS="${1:-$(ls -dt "$HOME"/.pi/agent/sessions/*/ 2>/dev/null | head -1)}"

echo "=== Tokens sent to the model on each turn ==="
python3 learn/lib/token_growth.py "$SESSIONS"

echo
echo "=== Standing cost: the fixed overhead re-paid on every single turn ==="

# vault/ is a separate repo and is not part of this one (see the README). Without
# it there is nothing to weigh, so say why rather than emitting shell errors.
if [ ! -d vault ]; then
    echo "  skipped: needs vault/ mounted here, which this repo does not ship."
    echo "  Point the script at any directory of prompt files to see the same effect."
    exit 0
fi
# 教練規則 ("coaching rules") stays untranslated on purpose: it is a real
# directory name inside vault/, a separate repo. An English glob matches nothing
# there, and the loop would then quietly weigh AGENTS.md alone rather than fail.
for f in vault/AGENTS.md vault/教練規則/*.md; do
    chars=$(wc -m < "$f" | tr -d ' ')
    printf "  %-34s %6s chars  ~= %5s tokens\n" "${f#vault/}" "$chars" "$((chars * 2 / 3))"
done
echo "  (rough estimate for Chinese: 1 character ~= 0.67 token)"
