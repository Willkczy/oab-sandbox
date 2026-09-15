# A thin layer over the base image. It deliberately stacks rather than
# rebuilds: the Rust binaries from the base are taken as-is, nothing Rust is
# compiled locally, and the disk and time cost stays at the npm/apt level.
FROM ghcr.io/openabdev/openab:stable-pi

USER root

# The task routing in the vault's AGENTS.md shells out to scripts/build_index.py,
# which rebuilds the problem-bank index, and scripts/pi_cost.py, which reports
# spend. The base image ships no python3, so both routes break outright without
# this.
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*

# This layer is the gate on model selection. pi's model catalogue is a static
# JSON file compiled into @earendil-works/pi-ai, not something fetched from
# Vertex at run time, so the npm version decides which models config/pi-coach is
# allowed to name at all. The base image pins pi 0.79.9, whose list stops at
# gemini-3.5-flash.
#
# One qualification, found on 2026-09-15. pi 0.84.2 also overlays a remote
# catalogue from pi.dev, refreshed in the background whenever it starts in rpc
# mode. squid denies pi.dev, so inside the sandbox the compiled list is still the
# whole list. On a machine without the gate, models can appear without an upgrade.
#
# 0.84.2 is the earliest release whose catalogue
# (dist/providers/data/google-vertex.json) contains gemini-3.7-flash; 0.83.0,
# 0.84.0 and 0.84.1 all stop at 3.6-flash. Do not trust the number alone:
# pi-coding-agent depends on pi-ai ^0.84.2, so a later rebuild can resolve a
# newer catalogue than this pin suggests. Read the list out of the built image
# instead:
#
#   docker run --rm --network none --entrypoint sh oab-sandbox:pi -c \
#     'grep -rho "gemini-3\.[0-9]-flash" /usr/local/lib/node_modules/@earendil-works | sort -u'
#
# The ACP handshake is measured, not assumed. On 2026-09-05 pi-acp 0.0.31 was
# driven directly over stdio against this image: initialize returned
# protocolVersion 1, session/new spawned pi-coach, and session/prompt answered
# with stopReason=end_turn, the agent's own banner reading "pi v0.84.2". The
# openab -> pi-acp -> pi hops therefore survive the bump. pi-acp itself stays at
# the base image's 0.0.31.
#
# It was driven by hand rather than through a real Discord conversation because
# openab's gateway cannot reach Discord from the internal network: the proxy
# settings in config.toml apply to the agent subprocess, not to openab itself.
# That is a separate, pre-existing limit which this bump neither caused nor
# fixes, and it is why the measurement covers the ACP hops only.
ARG PI_VERSION=0.84.2
RUN npm install -g @earendil-works/pi-coding-agent@${PI_VERSION} --retry 3

# openab keeps its own state under ~/.openab: the Discord thread-to-session map,
# reminders, and the multibot cache. run.sh mounts that path as the named volume
# oab-openab-home. The base image has no such directory, so Docker created the
# mount point, and with it the root of the volume, owned by root. openab runs as
# uid 1000, logged `failed to persist thread mapping ... Permission denied` on
# every session, and started each run with none of that state.
#
# Creating the directory here, owned by node, is the whole fix. When Docker mounts
# an empty named volume over a directory that exists in the image, it copies the
# directory's ownership onto the volume. On 2026-09-15 that held for a new volume
# and for an existing, empty, root-owned one alike; learn/dev/04 re-checks both.
# A volume that already holds files keeps its ownership, but openab could never
# have written to this one. ~/.pi never had the problem, because the base image
# already ships it owned by node.
RUN mkdir -p /home/node/.openab && chown node:node /home/node/.openab

USER node
