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
echo "=== The write boundary AGENTS.md claims (the convention) ==="
sed -n '/^## 寫入權限/,/^### 來源標記/p' "$(dirname "$0")/../vault/AGENTS.md" \
  | grep '^|' | sed 's/^/  /'

echo
echo "=== Review and practice areas are two sections of the same file ==="
grep -n '^## ' "$(dirname "$0")/../vault/模板/題目範本.md" | sed 's/^/  /'
