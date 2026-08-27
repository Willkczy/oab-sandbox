# 這個 image 唯一的職責是持有 SA 私鑰並換發短期 token。
# 刻意做得極小：沒有 shell 工具、沒有 curl、沒有 git —— 一旦被打進來，
# 手上能用的東西越少越好。
FROM node:22-trixie-slim

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund

COPY server.js ./

# node:22 image 內建 uid 1000 的 node 使用者。
USER node

EXPOSE 8080
CMD ["node", "server.js"]
