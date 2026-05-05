# OneWay backend — production deployment

End-to-end checklist for getting the OneWay API onto a real server. Pairs
with `infra/turn/` for the TURN box (separate VPS) and the iOS Xcode
project for the client.

## What just changed

| Phase | Component                                | Before                      | After                               |
| ----- | ---------------------------------------- | --------------------------- | ----------------------------------- |
| 1     | History / push tokens / voicemail meta   | JSON files                  | Postgres via Prisma                 |
| 2     | Voicemail audio                          | local disk                  | S3 / R2 (signed URLs) — local fallback retained |
| 3     | Auth                                     | `Bearer dev:<userId>`       | bcrypt + JWT (HS256), dev path gated by `JWT_AUTH_REQUIRED` |
| 4     | CallRegistry                             | per-process Map             | Redis-backed with pub/sub fan-out across instances |
| 5     | Rate limit / validation                  | manual zod / token bucket   | `express-rate-limit` per route, zod everywhere |
| 6     | TURN                                     | unauth'd, query identity    | auth'd; identity from authed user; rate-limited |
| 7     | PushKit                                  | best-effort, no retry       | retry queue, terminal-reason eviction, structured logs |
| 8     | Deployment                               | `npm run dev`               | Dockerfile + docker-compose + nginx |
| 9     | Logging                                  | `console.log`               | pino structured logger + per-request child logger |
| 10    | iOS resilience                           | basic backoff               | foreground/background-aware WS, JWT-aware HTTP, Keychain-backed token store |

## Files touched / added

```
server/
├── Dockerfile                              (NEW — multi-stage Alpine, non-root, tini PID 1)
├── docker-compose.yml                      (NEW — api + postgres + redis + nginx)
├── .dockerignore                           (NEW)
├── .env.example                            (UPDATED — full reference)
├── nginx/oneway.conf                       (NEW — TLS + WS upgrade + HSTS)
├── package.json                            (UPDATED — adds bcryptjs, jsonwebtoken, ioredis,
│                                                       pino, express-rate-limit, @aws-sdk/*)
├── prisma/schema.prisma                    (UPDATED — Postgres provider, auth fields,
│                                                       Call / CallHistoryEntry / Voicemail / PushToken)
├── PRODUCTION_DEPLOY.md                    (THIS FILE)
└── src/
    ├── index.ts                            (UPDATED — boot wiring, registry/storage selection)
    ├── lib/
    │   ├── db.ts                           (NEW — shared Prisma client)
    │   ├── logger.ts                       (NEW — pino + httpLogger middleware)
    │   ├── rateLimit.ts                    (NEW — factories per route)
    │   ├── redis.ts                        (NEW — ioredis client + sub)
    │   └── storage/
    │       ├── ObjectStorage.ts            (NEW — interface)
    │       ├── S3ObjectStorage.ts          (NEW — AWS / R2)
    │       └── LocalObjectStorage.ts       (NEW — fallback w/ HMAC-signed URLs)
    ├── middleware/auth.ts                  (UPDATED — JWT + dev fallback)
    ├── routes/
    │   ├── auth.ts                         (NEW — register / login)
    │   ├── calls.ts, livekit.ts, push.ts,
    │   ├── turn.ts, voicemail.ts           (UPDATED — rate limits + structured logs)
    └── services/
        ├── CallRegistry.ts                 (UPDATED — extracted ICallRegistry interface)
        ├── RedisCallRegistry.ts            (NEW — same surface, Redis-backed)
        ├── CallHistoryService.ts           (REWRITE — Prisma)
        ├── VoicemailService.ts             (REWRITE — uses ObjectStorage)
        ├── PushTokenStore.ts               (REWRITE — Prisma)
        └── VoIPPushService.ts              (UPDATED — retry queue + structured logs)
```

iOS:

```
OneWay/
├── App/AppEnvironment.swift                              (UPDATED — userID via AuthTokenStore)
├── Infrastructure/Services/
│   ├── AuthTokenStore.swift                              (NEW — Keychain-backed JWT)
│   └── NetworkCallSignalingClient.swift                  (UPDATED — bg/fg WS, JWT auth)
├── Features/Calls/
│   ├── CallHistoryManager.swift                          (UPDATED — auth header)
│   └── VoicemailManager.swift                            (UPDATED — auth header)
└── Infrastructure/Push/NetworkPushTokenRegistrar.swift   (UPDATED — auth header)
```

## One-time deploy

Pre-reqs: Ubuntu 22.04+ with Docker installed, a domain pointed at the box
(`api.oneway.app`), and Let's Encrypt certs already provisioned for that
hostname (`certbot --nginx -d api.oneway.app`).

```bash
# 1. Get the code
git clone <your-repo> /opt/oneway && cd /opt/oneway/server

# 2. Copy and fill the env
cp .env.example .env
nano .env              # set JWT_SECRET, POSTGRES_PASSWORD, LIVEKIT_*, TURN_*,
                       # APNS_*, S3_*, etc. See the file for the full list.

# 3. Drop the APNs .p8 into ./secrets so APNS_KEY_PATH resolves inside the container.
mkdir -p secrets
cp ~/AuthKey_ABCD123456.p8 secrets/apns.p8

# 4. Bring it up. First run pulls images, builds the API, runs migrations.
docker compose up -d --build

# 5. Tail logs.
docker compose logs -f api
docker compose logs -f nginx

# 6. Verify health from outside.
curl https://api.oneway.app/health
# → {"ok":true}

# 7. Verify auth.
curl -X POST https://api.oneway.app/api/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"king@oneway.app","password":"correct horse battery"}'
# → {"token":"eyJ...","user":{...}}
```

## Post-deploy hygiene

- `docker compose ps` all `healthy`.
- Check `redis-cli ping` from inside the redis container: `docker compose exec redis redis-cli ping`.
- `psql $DATABASE_URL -c '\dt'` lists `User`, `Call`, `CallHistoryEntry`, `Voicemail`, `PushToken`.
- `docker compose exec api wget -qO- http://localhost:3000/health` returns ok.

## Updating later

```bash
git pull
docker compose build api
docker compose up -d api          # rolling restart
```

`prisma migrate deploy` runs automatically on container start, so schema
changes propagate without a manual step. Always test migrations on staging
first — `migrate deploy` is non-interactive and won't reset data.

## Final test checklist

These are the smoke tests for the production stack. Run them from a clean
build of the iOS app pointed at `https://api.oneway.app`.

```text
1.  Register two accounts (User A, User B) via /api/auth/register.
    Confirm a JWT comes back. Open the iOS app on a real device, sign in
    as User A; confirm the token persists across app restarts.

2.  Confirm the WebSocket reconnects after backgrounding:
    - Foreground → "[Signaling] auth ok"
    - Background ~30s → server logs show the disconnect
    - Foreground → reconnect within 1s, "[Signaling] auth ok" again

3.  Place an outgoing call (User A → User B, both foregrounded).
    Confirm CallKit ringing on B, accept, both join the LiveKit room.
    History shows `completed` for both users with non-zero duration.

4.  Force-quit User B's app. Place a call from User A.
    Confirm CallKit ringing on the locked screen (PushKit working).
    Accept → app foregrounds → joins LiveKit. Logs: `[apn] push sent`.

5.  Place a call where User B doesn't answer. After 45s the registry flips
    to `missed`. Both clients see `call:ended` with reason `missed`.

6.  As caller, leave a voicemail (record → upload). On User B, confirm
    /api/voicemail/<userId> lists it. Tap to play; AVAudioPlayer plays.
    Listened flag toggles to true. Verify the audio file lives in S3/R2
    (or the api-uploads volume), not on the API container's tmpfs.

7.  Switch from WiFi → LTE during a connected call. TURN's `mobility`
    plus LiveKit reconnect keeps audio alive. Logs: `... mobility ...`.

8.  Hammer /api/calls/invite — confirm the rate limiter kicks in at the
    6th request inside 30s with 429.

9.  Try logging in with a wrong password — confirm 401, identical
    response time to a real login (timing pad working).

10. Restart the api container (`docker compose restart api`). All four
    Redis-backed states survive (active calls, push tokens, voicemails,
    history). The CallRegistry rebuilds its cache from Redis on first
    use; pub/sub re-subscribes; the WS reconnects.

11. Bring up a second api instance behind nginx (scale via
    `docker compose up -d --scale api=2`). Place a call from a client
    pinned to instance 1 to a callee pinned to instance 2. Pub/sub
    routes the `call:ringing` event to the right socket.

12. Trigger a synthetic APNs failure — `BadDeviceToken` evicts the token,
    soft 5xx triggers up to 3 retries with exponential backoff. Check
    the structured logs for `[apn] retrying push` lines.
```

## Things still to do post-MVP

- Real auth provider (Auth0 / Supabase Auth / custom) and remove the dev
  token path entirely.
- Rotate `JWT_SECRET` quarterly. Tokens are stateless — rotating
  invalidates all outstanding sessions, which is intended.
- Replace `LocalObjectStorage` entirely once S3/R2 is paid-for; remove
  the storage HMAC signer.
- Move Redis to a managed offering with persistence enabled
  (Upstash / Elasticache).
- Add Prometheus metrics + a Grafana dashboard for: active calls, push
  success rate, TURN allocations, JWT verifications/sec.
- Add background job processor (BullMQ on top of Redis) for
  voicemail-expiry sweeps and APNs retry persistence across restarts.
