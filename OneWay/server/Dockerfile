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

COPY tsconfig.json ./
COPY prisma ./prisma
COPY src ./src

RUN npx prisma generate
RUN npm run build

# ---- Runtime ---------------------------------------------------------------
FROM node:22-alpine AS runtime

RUN apk add --no-cache libc6-compat openssl tini

WORKDIR /app
ENV NODE_ENV=production
ENV PORT=3000

# Drop privileges. UID/GID match the official `node` user.
RUN addgroup -g 1001 -S oneway && adduser -u 1001 -S oneway -G oneway

# Pre-create persistent dirs the app expects to write to.
RUN mkdir -p /app/uploads /app/data && chown -R oneway:oneway /app

COPY --from=builder --chown=oneway:oneway /app/package.json /app/package-lock.json* ./
COPY --from=builder --chown=oneway:oneway /app/node_modules ./node_modules
COPY --from=builder --chown=oneway:oneway /app/dist ./dist
COPY --from=builder --chown=oneway:oneway /app/prisma ./prisma

# Volume mount points — voicemails (when local), Prisma data, env-configured
# secrets like the APNs .p8.
VOLUME ["/app/uploads", "/app/data", "/etc/oneway"]

USER oneway
EXPOSE 3000

# tini = proper PID 1 reaping for SIGTERM forwarding.
ENTRYPOINT ["/sbin/tini", "--"]
# Run `prisma migrate deploy` then start the server. `migrate deploy` is
# idempotent — safe on every container start.
CMD ["sh", "-c", "npx prisma migrate deploy && node dist/index.js"]
