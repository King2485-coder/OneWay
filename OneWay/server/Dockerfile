# OneWay API server — multi-stage build.
#
# Stage 1 ("builder") installs all deps and runs `tsc` + `prisma generate`.
# Stage 2 ("runtime") copies only what's needed to run, on a slim Alpine
# image with no build toolchain. Final image is ~150 MB.

# ---- Builder ---------------------------------------------------------------
FROM node:22-alpine AS builder

# Build deps for native modules (bcrypt's optional native; we ship bcryptjs
# so this layer is small but kept for prisma engines).
RUN apk add --no-cache libc6-compat openssl

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci
# Ensure Twilio SDK is present in runtime even if local lockfiles lag behind.
RUN npm install twilio --no-save

COPY tsconfig.json ./
COPY prisma ./prisma
COPY src ./src
COPY scripts ./scripts

RUN npx prisma generate
RUN npm run build

# ---- Runtime ---------------------------------------------------------------
FROM node:22-alpine AS runtime

RUN apk add --no-cache libc6-compat openssl tini su-exec

WORKDIR /app
ARG GIT_COMMIT_SHA=unknown
ENV NODE_ENV=production
ENV PORT=3000
ENV GIT_COMMIT_SHA=$GIT_COMMIT_SHA

# Drop privileges. UID/GID match the official `node` user.
RUN addgroup -g 1001 -S oneway && adduser -u 1001 -S oneway -G oneway

# Pre-create persistent dirs the app expects to write to.
RUN mkdir -p /var/lib/oneway/uploads /app/data && chown -R oneway:oneway /var/lib/oneway /app

COPY --from=builder --chown=oneway:oneway /app/package.json /app/package-lock.json* ./
COPY --from=builder --chown=oneway:oneway /app/node_modules ./node_modules
COPY --from=builder --chown=oneway:oneway /app/dist ./dist
COPY --from=builder --chown=oneway:oneway /app/prisma ./prisma
COPY --from=builder --chown=oneway:oneway /app/scripts ./scripts

# Render mounts persistent storage at /app/data. Keep the directories in the
# image as well so local container runs remain deterministic.

EXPOSE 3000

# tini = proper PID 1 reaping for SIGTERM forwarding.
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["sh", "/app/scripts/render-entrypoint.sh"]
