#!/bin/sh
# Acceptance check: after sessions moved to tmpfs, does pi_cost.py still find the
# right directory?
#
# What it tests  : which directory resolve_sessions_dir() picks in two situations
#   case A       : inside the sandbox, started through pi-coach -> should use
#                  /tmp/sessions
#   case B       : no PI_SESSION_DIR and no /tmp/sessions -> should fall back to
#                  ~/.pi/agent/sessions
# What to expect : both cases print the directory they actually scanned, instead
#                  of staying silent about it
# Cost           : case A makes one real Vertex call (about $0.0001)
# Prerequisites  : oab-proxy and oab-broker must be running
# Re-run         : ./learn/dev/02-cost-script-fix.sh

set -e
cd "$(dirname "$0")/../.."
. learn/lib/project-id.sh

run() {
    docker run --rm --network oab-int \
        --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m \
        -v oab-pi-home:/home/node/.pi \
        --cap-drop ALL --security-opt=no-new-privileges --user 1000:1000 \
        -e GOOGLE_CLOUD_PROJECT=$GCP_PROJECT \
        -e GOOGLE_CLOUD_LOCATION=global \
        -e GCE_METADATA_HOST=oab-broker:8080 \
        -e HTTPS_PROXY=http://oab-proxy:3128 \
        -e NO_PROXY=localhost,127.0.0.1,oab-proxy,oab-broker \
        -v "$PWD/config/pi-coach:/home/node/bin/pi-coach:ro" \
        -v "$PWD/config/adc-marker.json:/home/node/.config/gcloud/application_default_credentials.json:ro" \
        -v "$PWD/vault:/workspace" \
        --entrypoint sh oab-sandbox:pi -c "$1"
}

echo "########## Case A: inside the sandbox, started through pi-coach ##########"
run '
    cd /workspace
    /home/node/bin/pi-coach -p "Reply with exactly one word: ok" | sed "s/^/  model said: /"
    echo
    echo "  actually written to : $(ls /tmp/sessions/*.jsonl | tail -1)"
    echo "  --- pi_cost.py --current ---"
    PI_SESSION_DIR=/tmp/sessions python3 scripts/pi_cost.py --current | head -4 | sed "s/^/  /"
'

echo
echo "########## Case B: host mode (no PI_SESSION_DIR, no /tmp/sessions) ##########"
run '
    cd /workspace
    echo "  PI_SESSION_DIR = ${PI_SESSION_DIR:-(unset)}"
    echo "  /tmp/sessions  = $([ -d /tmp/sessions ] && echo present || echo absent)"
    echo "  --- pi_cost.py --current ---"
    python3 scripts/pi_cost.py --current | head -3 | sed "s/^/  /"
'
