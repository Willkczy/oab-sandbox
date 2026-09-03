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
# Unlike the 0.79.9 -> 0.82.1 bump, this one is NOT backed by a handshake
# measurement: pi 0.84.2 against the base image's pi-acp 0.0.31 has not been
# tested here. pi-acp itself still stays at the base image's 0.0.31, so if the
# agent stops responding after this bump, an ACP version mismatch is the first
# thing to check.
ARG PI_VERSION=0.84.2
RUN npm install -g @earendil-works/pi-coding-agent@${PI_VERSION} --retry 3

USER node
