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

USER node
