#!/bin/sh
# Experiment: does pi's --session-dir really change where session files land?
#
# What it tests  : with --session-dir set, where the .jsonl ends up and whether
#                  anything new still appears in the default location
# What to expect : the file shows up in the given directory, and nothing new
#                  arrives in ~/.pi/agent/sessions
# Why it matters : this is the assumption the whole "move sessions to tmpfs to
#                  make an accidental read cheap" change rests on
# Cost           : makes one real Vertex call (about $0.0001)
# Prerequisites  : oab-proxy and oab-broker must be running (./run.sh, or start
#                  them by hand)
# Re-run         : ./learn/09-session-dir.sh [session dir]
#                  no argument means /tmp/sessions

set -e
cd "$(dirname "$0")/.."
. learn/lib/project-id.sh
SESSION_DIR="${1:-/tmp/sessions}"

docker run --rm --network oab-int \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    -v oab-pi-home:/home/node/.pi \
    --cap-drop ALL --security-opt=no-new-privileges --user 1000:1000 \
    -e GOOGLE_CLOUD_PROJECT=$GCP_PROJECT \
    -e GOOGLE_CLOUD_LOCATION=global \
    -e GCE_METADATA_HOST=oab-broker:8080 \
    -e HTTPS_PROXY=http://oab-proxy:3128 \
    -e NO_PROXY=localhost,127.0.0.1,oab-proxy,oab-broker \
    -e SESSION_DIR="$SESSION_DIR" \
    -v "$PWD/config/adc-marker.json:/home/node/.config/gcloud/application_default_credentials.json:ro" \
    --entrypoint sh oab-sandbox:pi -c '
        echo "=== Calling pi (--session-dir $SESSION_DIR) ==="
        env -u HOME pi --model google-vertex/gemini-3.6-flash \
            --session-dir "$SESSION_DIR" \
            -p "Reply with exactly one word: ack" | sed "s/^/  model said: /"

        echo
        echo "=== What is in the directory we asked for ==="
        find "$SESSION_DIR" -type f 2>/dev/null | sed "s/^/  /" || echo "  (directory does not exist)"

        echo
        echo "=== Anything new in the default location in the last 2 minutes? ==="
        found=$(find /home/node/.pi/agent/sessions -type f -newermt "-2 minutes" 2>/dev/null)
        if [ -z "$found" ]; then
            echo "  (nothing new -- --session-dir took effect)"
        else
            echo "$found" | sed "s/^/  WARNING: /"
        fi
    '
