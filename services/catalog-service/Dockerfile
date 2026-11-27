# catalog-service — Node.js 20 (Alpine)
FROM node:20-alpine

ENV NODE_ENV=production \
    CATALOG_SERVICE_PORT=8001
WORKDIR /app

COPY package.json package-lock.json* ./
RUN if [ -f package-lock.json ]; then npm ci --omit=dev; else npm install --omit=dev; fi \
    && npm cache clean --force

COPY src ./src

USER node
EXPOSE 8001
HEALTHCHECK --interval=15s --timeout=4s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:${CATALOG_SERVICE_PORT}/health >/dev/null || exit 1

CMD ["node", "src/server.js"]
