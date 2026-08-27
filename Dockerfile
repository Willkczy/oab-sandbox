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

# The base image pins pi 0.79.9, whose @earendil-works/pi-ai model list stops at
# gemini-3.5-flash. 3.6-flash is the only model that both held the coaching rules
# under test and came in cheaper than pro, so this bump is not optional.
#
# The upgrade risk is known to be zero: pi 0.82.1 with pi-acp 0.0.31 was measured
# on the main machine and the ACP handshake completes in 211ms, so there is
# nothing a downgrade comparison would tell us. pi-acp itself stays at the base
# image's 0.0.31.
ARG PI_VERSION=0.82.1
RUN npm install -g @earendil-works/pi-coding-agent@${PI_VERSION} --retry 3

USER node
