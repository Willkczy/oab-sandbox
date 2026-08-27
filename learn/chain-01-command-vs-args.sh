#!/bin/sh
# ─────────────────────────────────────────────────────────────────────
# Call chain, side track 01: "program name" and "arguments" are two separate slots
#
# What it tests:
#   The same string, "greet --loud hello", launched two different ways, with
#   completely different results.
#
# What to expect:
#   [1] through a shell     -> works. The shell splits the string into a program
#                              name plus 2 arguments.
#   [2] without a shell     -> fails. The whole string is treated as one filename,
#                              and no such file exists.
#   [3] behind a wrapper    -> works. The arguments now live *inside* a file.
#
# Why it matters:
#   pi-acp launches pi exactly the way [2] does, without a shell, which is the
#   entire reason this project needs the config/pi-coach wrapper.
#
# This experiment touches no docker and changes nothing in the project -- it works
# in a temporary directory only.
#
# Re-run:  ./learn/chain-01-command-vs-args.sh
# ─────────────────────────────────────────────────────────────────────
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Build a fake `greet` whose only job is to report which arguments it received
cat > "$WORK/greet" <<'EOF'
#!/bin/sh
echo "    greet started. I received $# argument(s): $*"
EOF
chmod +x "$WORK/greet"

# Make the greet we just built findable
PATH="$WORK:$PATH"
export PATH


echo "=== [1] Launched through a shell ==="
echo '    how: sh -c "greet --loud hello"'
sh -c "greet --loud hello"
echo


echo "=== [2] Launched without a shell (the way pi-acp does it) ==="
echo '    how: shove the whole string "greet --loud hello" into the program-name slot'
python3 "$HERE/lib/spawn_demo.py" "greet --loud hello"
echo


echo "=== [3] Still no shell, but going through a wrapper file first ==="
# The wrapper's contents: the arguments are baked into the file
cat > "$WORK/greet-loud" <<'EOF'
#!/bin/sh
exec greet --loud hello "$@"
EOF
chmod +x "$WORK/greet-loud"

echo '    First build a file called greet-loud containing:'
echo '        exec greet --loud hello "$@"'
echo '    then put a single clean filename in the program-name slot: greet-loud'
python3 "$HERE/lib/spawn_demo.py" "greet-loud"
