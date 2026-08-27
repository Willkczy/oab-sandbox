# 沙箱用的薄層 image。刻意「只疊、不重建」——
# 基底那層的 Rust binary 直接沿用，本機不編譯任何 Rust，
# 磁碟與時間成本都留在 npm/apt 這一級。
FROM ghcr.io/openabdev/openab:stable-pi

USER root

# AGENTS.md 的任務路由要跑 scripts/build_index.py（重建題庫索引）
# 與 scripts/pi_cost.py（查花費）。基底 image 沒有 python3，兩條路由會直接斷。
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*

# 基底 image 釘 pi 0.79.9，其 @earendil-works/pi-ai 模型清單裡沒有
# gemini-3.6-flash（最新的 flash 只到 3.5）。而 3.6-flash 是唯一
# 「實測守得住教練規則且比 pro 便宜」的選項，所以要升版。
#
# 升版風險已知為零：主力機實測過 pi 0.82.1 + pi-acp 0.0.31 的 ACP 握手正常
# （211ms），不需要降版比對。pi-acp 維持基底的 0.0.31 不動。
ARG PI_VERSION=0.82.1
RUN npm install -g @earendil-works/pi-coding-agent@${PI_VERSION} --retry 3

USER node
