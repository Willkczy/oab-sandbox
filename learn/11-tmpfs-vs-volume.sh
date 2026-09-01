#!/bin/sh
# Experiment: tmpfs versus a volume -- which one survives the container?
#
# What it tests  : the same act, "write one file", performed into a tmpfs and
#                  into a volume, and what becomes of each afterwards
# What to expect : after a restart the tmpfs file is gone and the volume file
#                  is still there
# Why it matters : development ① moved pi's sessions off a volume and onto a
#                  tmpfs, and it is exactly this "gone on shutdown" property
#                  that the change was buying
# Cost           : none; no model is called
# Re-run         : ./learn/11-tmpfs-vs-volume.sh
#
# Uses a throwaway volume of its own, so oab-pi-home is never touched.
#
# Note: this runs as --user 0:0 because a freshly created Docker volume belongs
#       to root, while the image defaults to uid 1000 (node), which could not
#       write into it. oab-pi-home does not have that problem: /home/node/.pi
#       already belongs to node inside the image, and a volume mounted there
#       inherits that owner.

IMAGE=oab-sandbox:pi
VOL=oab-tmpfs-demo

docker volume create "$VOL" >/dev/null

echo "=== First start: write one file into each ==="
docker run --rm --entrypoint sh --user 0:0 \
    --tmpfs /demo-tmpfs:rw,size=8m \
    -v "$VOL:/demo-volume" \
    "$IMAGE" -c '
        echo "I live in memory" > /demo-tmpfs/note.txt
        echo "I live on disk"   > /demo-volume/note.txt
        echo "  wrote /demo-tmpfs/note.txt  : $(cat /demo-tmpfs/note.txt)"
        echo "  wrote /demo-volume/note.txt : $(cat /demo-volume/note.txt)"
        echo
        echo "  filesystem type behind each path:"
        grep -E " /demo-tmpfs | /demo-volume " /proc/mounts | awk "{printf \"    %-16s %s\n\", \$2, \$3}"
    '

echo
echo "=== The container is gone (--rm). Start again, mounting the same things ==="
docker run --rm --entrypoint sh --user 0:0 \
    --tmpfs /demo-tmpfs:rw,size=8m \
    -v "$VOL:/demo-volume" \
    "$IMAGE" -c '
        printf "  /demo-tmpfs/note.txt  : "
        cat /demo-tmpfs/note.txt 2>/dev/null || echo "gone -- the memory was reclaimed"
        printf "  /demo-volume/note.txt : "
        cat /demo-volume/note.txt 2>/dev/null || echo "gone"
    '

docker volume rm "$VOL" >/dev/null
echo
echo "(the throwaway volume is cleaned up; oab-pi-home was never touched)"
