# This image has exactly one job: hold the SA private key and exchange it for
# short-lived tokens. It is kept deliberately bare -- no shell tooling, no curl,
# no git. If someone does get in here, the less there is to reach for the
# better.
FROM node:22-trixie-slim

WORKDIR /app

# Lockfile plus npm ci, not npm install: this is the only container holding the
# SA private key, and a drifting dependency tree is a drifting trust boundary.
# npm ci installs exactly what the lockfile pins, and fails outright when the
# lockfile and package.json disagree instead of quietly resolving something
# newer.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

COPY server.js ./

# The node:22 image already ships a "node" user at uid 1000.
USER node

EXPOSE 8080
CMD ["node", "server.js"]
