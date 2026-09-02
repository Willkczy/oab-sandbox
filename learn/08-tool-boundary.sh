#!/bin/sh
# Experiment: how far apart are the write permissions AGENTS.md claims and the
# tools the agent actually holds?
#
# What it tests  : the real tool list pi exposes, against the "write permissions"
#                  rules in AGENTS.md
# What to expect : every tool works at file granularity (write/edit/bash) and
#                  none at section granularity -- so that permission table can
#                  only ever be a convention, never an enforceable boundary
# Why it matters : a pi upgrade that adds new tools changes the attack surface,
#                  and this needs revisiting when it does
# Re-run         : ./learn/08-tool-boundary.sh

IMAGE=oab-sandbox:pi
TOOLS=/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/tools

echo "=== Tools the agent actually holds (the enforceable boundary) ==="
docker run --rm --entrypoint sh "$IMAGE" -c "ls $TOOLS" \
  | grep -v '\.map$\|\.d\.ts$' | sed 's/\.js$//' \
  | grep -E '^(bash|read|write|edit|find|grep|ls)$' | sed 's/^/  /'

echo
# The second half compares against the vault's own rules. vault/ is a separate
# repo (see the README), so without it, stop here having shown the real boundary.
if [ ! -f "$(dirname "$0")/../vault/AGENTS.md" ]; then
    echo
    echo "The other half of this comparison needs vault/AGENTS.md, which lives in a"
    echo "separate repo. The list above is the enforceable boundary; the claimed one"
    echo "is a table of per-section write permissions that no tool can enforce."
    exit 0
fi

echo "=== The write boundary AGENTS.md claims (the convention) ==="
# 寫入權限 ("write permissions") and 來源標記 ("source marking") stay
# untranslated on purpose: they are headings inside vault/AGENTS.md, a separate
# repo written in Chinese. Translated, this range matches nothing and the block
# prints an empty table -- a silent wrong answer rather than an error.
sed -n '/^## 寫入權限/,/^### 來源標記/p' "$(dirname "$0")/../vault/AGENTS.md" \
  | grep '^|' | sed 's/^/  /'

echo
echo "=== Review and practice areas are two sections of the same file ==="
# 模板/題目範本.md ("templates/problem template") stays untranslated for the same
# reason: it is a real path in vault/, not prose. Renaming it here would make the
# file simply not exist.
grep -n '^## ' "$(dirname "$0")/../vault/模板/題目範本.md" | sed 's/^/  /'
