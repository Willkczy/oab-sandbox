#!/bin/sh
# Stop the whole sandbox. Volumes and networks are left in place, so the next
# run.sh picks up where this left off.
# To clear the volumes too: docker volume rm oab-pi-home oab-openab-home
set -e
docker rm -f oab-sandbox oab-broker oab-proxy >/dev/null 2>&1 || true
echo "sandbox stopped. production on the other machine is unaffected."
