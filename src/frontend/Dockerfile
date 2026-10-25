FROM node:24-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

FROM node:24-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
ARG NEXT_PUBLIC_USE_MOCK_AUTH=false
ARG API_PROXY_TARGET
ARG NEXT_PUBLIC_API_BASE_URL
ARG NEXT_PUBLIC_API_URL
ENV NEXT_PUBLIC_USE_MOCK_AUTH=$NEXT_PUBLIC_USE_MOCK_AUTH
ENV API_PROXY_TARGET=$API_PROXY_TARGET
ENV NEXT_PUBLIC_API_BASE_URL=$NEXT_PUBLIC_API_BASE_URL
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build
# Ship only runtime dependencies; lint and test tooling stays in the build stage.
RUN npm prune --omit=dev

FROM node:24-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV HOSTNAME=0.0.0.0
ENV PORT=3000
ENV NEXT_TELEMETRY_DISABLED=1
# Patch the base OS, and drop the package managers the server never uses.
RUN apk upgrade --no-cache \
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
       /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /opt/yarn-* \
       /usr/local/bin/yarn /usr/local/bin/yarnpkg
RUN addgroup -S nodejs && adduser -S nextjs -G nodejs
COPY --from=builder --chown=nextjs:nodejs /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next ./.next
COPY --from=builder --chown=nextjs:nodejs /app/node_modules ./node_modules
COPY --from=builder --chown=nextjs:nodejs /app/package.json ./package.json
COPY --from=builder --chown=nextjs:nodejs /app/next.config.ts ./next.config.ts
USER nextjs
EXPOSE 3000
CMD ["node", "node_modules/next/dist/bin/next", "start"]
