# OneWay TURN/STUN — production deployment guide

End-to-end coturn deployment for the OneWay iOS app. Covers infrastructure
sizing, Docker setup, ephemeral REST-API credentials, the Express helper
endpoint, the iOS integration, testing, and the security checklist.

Contents
- [1. Infrastructure plan](#1-infrastructure-plan)
- [2. Docker setup](#2-docker-setup)
- [3. Ports & relay range](#3-ports--relay-range)
- [4. Authentication (REST API shared secret)](#4-authentication)
- [5. Backend helper — /api/turn-credentials](#5-backend-helper)
- [6. iOS integration](#6-ios-integration)
- [7. Testing checklist](#7-testing-checklist)
- [8. Deployment commands](#8-deployment-commands)
- [9. LiveKit compatibility](#9-livekit-compatibility)
- [10. Security checklist](#10-security-checklist)

## 1. Infrastructure plan

### VPS sizing

TURN is bandwidth-bound, not CPU-bound. Each *relayed* call carries roughly:

| Call type      | Per-call up + down | Notes                     |
| -------------- | ------------------ | ------------------------- |
| Voice (Opus)   | ~80 KB/s           | both directions combined  |
| Video (VP8 SD) | ~600 KB/s          | one stream, both directions |
| Video (HD)     | ~1.5 MB/s          | adaptive, peaks higher    |

A 1 vCPU / 2 GB RAM VPS with a 1 Gbps NIC handles **~150 concurrent video
calls** comfortably. Pick the smallest box your provider sells with **a high
egress bandwidth cap**:

- DigitalOcean s-1vcpu-2gb (4 TB egress) — fine for ~50 concurrent calls/day
- Hetzner CX22 (20 TB) — best $/GB if you expect real volume
- AWS t4g.small + bandwidth charges — avoid; TURN egress will dominate cost

**Region:** put the VPS where most of your users live. ICE picks the lowest-
latency candidate, but TURN-relayed flows always pay the round trip to the
relay. You can run two TURNs and let the client try both via the `iceServers`
array.

### DNS records

```
turn.oneway.app   A     <VPS_PUBLIC_IPv4>
turn.oneway.app   AAAA  <VPS_PUBLIC_IPv6>     ; optional
```

Don't put TURN behind a CDN or load balancer that doesn't speak STUN — most
don't. Direct A record is correct.

### Firewall rules

| Port          | Proto | Purpose                                 |
| ------------- | ----- | --------------------------------------- |
| 22            | TCP   | SSH (lock down to your jump host)       |
| 80            | TCP   | certbot HTTP-01 only — close otherwise  |
| 3478          | UDP   | STUN + TURN over UDP                    |
| 3478          | TCP   | TURN over TCP (firewalled networks)     |
| 5349          | TCP   | TURN over TLS (DPI-ed networks)         |
| 49160–49200   | UDP   | media relay range                       |

Everything else: **deny inbound**. `deploy.sh` configures ufw exactly this way.

### Production security checklist

- [ ] `external-ip` set to the VPS public IP
- [ ] `static-auth-secret` is a 64-hex-char random value
- [ ] `denied-peer-ip` blocks all RFC1918 ranges (it does, by default)
- [ ] Let's Encrypt cert installed and the renewal hook reloads coturn
- [ ] Logs do **not** have `verbose` enabled in production
- [ ] `NSLocalNetworkUsageDescription` set in iOS Info.plist (already done)
- [ ] Backend serves `/api/turn-credentials` over HTTPS only
- [ ] Shared secret rotated quarterly (see §10)
- [ ] `total-quota` and `user-quota` set; alerts on hitting either

## 2. Docker setup

All four files are in [`infra/turn/`](../infra/turn/):

```
infra/turn/
├── docker-compose.yml
├── turnserver.conf
├── .env.example
└── deploy.sh
```

**Why host networking?** coturn allocates an ephemeral UDP port from the
relay range *per allocation*. Docker's userland NAT can't expose a 40-port
UDP range performantly — packets get reordered and the relay performance
drops by an order of magnitude. `network_mode: host` binds coturn to the
VPS NIC directly. The container drops every Linux capability except
`NET_BIND_SERVICE`.

## 3. Ports & relay range

The relay range is set in three places — all three must agree:

1. `turnserver.conf`: `min-port` / `max-port`
2. `infra/turn/.env`: `TURN_MIN_PORT` / `TURN_MAX_PORT`
3. ufw rule (set by `deploy.sh`)

To widen the range later (more concurrent calls):

```bash
cd /opt/oneway-turn
sed -i 's/^TURN_MIN_PORT=.*/TURN_MIN_PORT=49000/'  .env
sed -i 's/^TURN_MAX_PORT=.*/TURN_MAX_PORT=49500/'  .env
sudo ufw allow 49000:49500/udp
./deploy.sh        # re-renders turnserver.conf and reloads container
```

Each allocation uses 1 UDP port for the lifetime of the call. Plan ~2× peak
concurrent allocations to avoid running out under churn.

## 4. Authentication

OneWay uses **TURN REST API** auth (`use-auth-secret` + `static-auth-secret`).
The flow:

1. iOS hits `GET https://api.oneway.is/api/turn-credentials`.
2. Backend computes:
   - `username = "<unix_expiry>:<userId>"`
   - `credential = base64(HMAC-SHA1(SHARED_SECRET, username))`
3. Backend returns the bundle. iOS hands it to LiveKit/WebRTC.
4. coturn re-derives the same HMAC and accepts the binding.

**No long-term passwords ever exist.** The shared secret never leaves the
VPS or the backend. Credentials expire after `TURN_TTL_SECONDS` (default
12 h) — clients refresh themselves.

## 5. Backend helper

[`server/src/routes/turn.ts`](../server/src/routes/turn.ts) implements the
endpoint, mounted in `server/src/index.ts` at `/api/turn-credentials`.

Required env on the backend:

```bash
TURN_SHARED_SECRET=<same value as turnserver.conf static-auth-secret>
TURN_HOSTNAME=turn.oneway.app
TURN_TTL_SECONDS=43200      # optional, default 12h
```

Response shape:

```json
{
  "iceServers": [
    {
      "urls": [
        "stun:turn.oneway.app:3478",
        "turn:turn.oneway.app:3478?transport=udp",
        "turn:turn.oneway.app:3478?transport=tcp",
        "turns:turn.oneway.app:5349?transport=tcp"
      ],
      "username": "1719999999:user-abc",
      "credential": "Vh3+...=="
    }
  ],
  "ttl": 43200,
  "expiresAt": 1719999999
}
```

The endpoint returns `503` (not `500`) if `TURN_SHARED_SECRET` or
`TURN_HOSTNAME` are missing — that's how the iOS client knows TURN is
intentionally absent and should fall back to host candidates.

## 6. iOS integration

Two files:

- [`Infrastructure/Services/TurnCredentialsService.swift`](Infrastructure/Services/TurnCredentialsService.swift)
  — actor that fetches and caches credentials. HTTPS-only by default, 10 s
  request timeout, automatic refresh 5 min before expiry. Concurrent callers
  share one in-flight request.
- [`Infrastructure/Services/LiveKitTransport.swift`](Infrastructure/Services/LiveKitTransport.swift)
  — already updated. At `connect()` it grabs the bundle and passes it into
  `ConnectOptions(rtcConfiguration:)`. If the fetch fails, the call still
  goes through with whatever default ICE config LiveKit ships with — TURN
  is best-effort.

Wired in `AppEnvironment.live`:

```swift
let turnService = TurnCredentialsService(
    baseURL: apiBase,
    allowInsecureForLocalDev: apiBase.scheme == "http"
)
callService = LiveKitCallService(
    transport: LiveKitTransport(turnCredentials: turnService),
    signaling: StubCallSignalingClient()
)
```

### Error handling, in order of caller-friendliness

| Failure                          | What happens                                  |
| -------------------------------- | --------------------------------------------- |
| `503` from backend (not configured) | LiveKit uses default ICE; call may still work |
| `URLError.timedOut` (10 s)       | `Failure.timeout`; logs, continues without TURN |
| `Failure.insecureScheme`         | Refuses non-HTTPS in release builds           |
| `Failure.decoding`               | Logs the decode error; continues without TURN |
| HMAC mismatch at coturn          | WebRTC reports `iceConnectionState == failed`; UI surfaces "couldn't connect" |

If you ever need to force TURN-only (debugging firewalls), set
`config.iceTransportPolicy = .relay` in `makeRTCConfiguration` — the comment
inside `LiveKitTransport.swift` flags the line.

### HTTPS requirement

`TurnCredentialsService.fetch()` rejects `http://` URLs unless the host is a
LAN address (`localhost`, `127.0.0.1`, `192.168.*`, `10.*`, `172.16-31.*`)
*and* `allowInsecureForLocalDev: true` was passed. That carve-out exists
purely for the simulator pointing at the dev backend on your laptop.

## 7. Testing checklist

Run from the VPS unless noted otherwise. Replace `turn.oneway.app` if you
test with a different host.

```bash
# 1. coturn is running
docker compose ps                                       # State: Up
ss -lntu | grep -E ':(3478|5349)'                       # listens UDP+TCP 3478, TCP 5349
docker compose logs --tail=50 coturn                    # no `error:` lines

# 2. STUN works (any public stunclient)
turnutils_stunclient turn.oneway.app 3478            # returns Mapped Address

# 3. TURN UDP allocation (will need real creds — generate one quickly)
SECRET=<TURN_SHARED_SECRET>
EXP=$(( $(date +%s) + 600 ))
USER="$EXP:test"
PASS=$(echo -n "$USER" | openssl dgst -sha1 -hmac "$SECRET" -binary | base64)
turnutils_uclient -v -u "$USER" -w "$PASS" turn.oneway.app

# 4. TURN TCP
turnutils_uclient -t -v -u "$USER" -w "$PASS" turn.oneway.app

# 5. TURN TLS
turnutils_uclient -t -S -v -u "$USER" -w "$PASS" turn.oneway.app

# 6. Logs show allocations (during the test runs above)
tail -f infra/turn/logs/turnserver.log | grep -i 'allocation'

# 7. iPhone cellular test (run from the iPhone, NOT the VPS)
#    Open OneWay, place a call. In Xcode console, look for:
#      [TURN] credential fetch failed     ← bad: backend or HTTPS issue
#      ICE Selected pair: relay/...       ← good: routed through TURN

# 8. WiFi → cellular handoff test (mobility)
#    Place a call on WiFi, walk out of range so iOS hands to LTE. Call
#    should keep audio. coturn's `mobility` flag (already on) handles the
#    new client IP. Monitor with: tail -f logs/turnserver.log | grep mobility
```

## 8. Deployment commands

Fresh Ubuntu 22.04/24.04 VPS:

```bash
# 0. ssh in as a user with sudo, cd to /opt
ssh root@$VPS_IP
adduser oneway && usermod -aG sudo oneway && su - oneway
sudo mkdir -p /opt/oneway-turn && sudo chown $USER /opt/oneway-turn
cd /opt/oneway-turn

# 1. Pull infra files (scp from your laptop, or git clone)
scp -r ./infra/turn/* "$USER@$VPS_IP:/opt/oneway-turn/"

# 2. Configure
cp .env.example .env
nano .env              # fill TURN_PUBLIC_IP, TURN_SHARED_SECRET, LE_EMAIL

# 3. Bootstrap (installs Docker, ufw, certbot, starts coturn)
chmod +x deploy.sh
./deploy.sh

# 4. Verify
docker compose logs -f coturn

# 5. Restart after config change
docker compose restart coturn

# 6. Pull a newer coturn image
docker compose pull && docker compose up -d

# 7. View live logs
tail -f /opt/oneway-turn/logs/turnserver.log

# 8. Rotate shared secret (see §10)
openssl rand -hex 32                # → put in .env AND backend env
./deploy.sh                         # re-renders turnserver.conf
docker compose up -d                # zero-downtime; existing calls drain
```

## 9. LiveKit compatibility

### LiveKit Cloud (default)

LiveKit Cloud already ships with TURN. Passing your own `iceServers` via
`ConnectOptions(rtcConfiguration:)` *adds* to LiveKit's defaults; the
client picks whichever path connects first. Useful for:

- Cutting over to your own TURN gradually
- Geographic redundancy (your TURN closer to a user than LiveKit's)
- DPI-bypass via `turns://` when LiveKit's TURN is blocked

### Self-hosted LiveKit

When you self-host LiveKit (or its open-source SFU), point its server config
at this same coturn:

```yaml
# livekit.yaml
rtc:
  use_external_ip: true
  turn_servers:
    - host: turn.oneway.app
      port: 3478
      protocol: udp
      username: ""        # populate at runtime via REST API auth
      credential: ""
```

LiveKit also supports the REST API auth flow — it'll mint per-allocation
credentials using the same `static-auth-secret`. Configure with:

```yaml
turn:
  enabled: true
  domain: turn.oneway.app
  loadBalancerOnly: false
  external_tls: true
  cert_file: /etc/livekit/certs/fullchain.pem
  key_file:  /etc/livekit/certs/privkey.pem
```

### Raw WebRTC (if you ever drop LiveKit)

The `iceServers` array returned by `/api/turn-credentials` is exactly the
shape `RTCPeerConnection` expects. Drop LiveKit, keep `TurnCredentialsService`,
and pass the same array straight to `RTCConfiguration.iceServers`.

## 10. Security checklist

| Threat                              | Mitigation                                         |
| ----------------------------------- | -------------------------------------------------- |
| Open relay abuse                    | `denied-peer-ip` blocks all RFC1918 / loopback     |
| Credentials baked into the app      | Never; app fetches `/api/turn-credentials` per call |
| Replay of stolen credentials        | TTL ≤ 12 h + `stale-nonce=600`; rotate secret to invalidate all |
| Brute-force on `static-auth-secret` | 64-hex-char (256-bit) random; rotate quarterly     |
| Open ports beyond what's needed     | ufw default-deny; only 22, 80, 3478, 5349, relay range |
| MITM on credentials in flight       | Backend HTTPS-only; iOS rejects `http://`          |
| TLS downgrade                       | `no-tlsv1`, `no-tlsv1_1`, modern cipher list       |
| Logs leak peer IPs                  | `verbose` disabled in prod; `simple-log` only      |
| DoS via connection flood            | `total-quota=200`, `user-quota=12`, ufw rate-limit on 22 |
| Cert expiry takes the server down   | certbot renewal hook HUPs coturn automatically     |

### Rotating the shared secret

```bash
# 1. Generate new secret
NEW=$(openssl rand -hex 32)

# 2. Update VPS
ssh oneway@$VPS_IP
cd /opt/oneway-turn
sed -i "s/^TURN_SHARED_SECRET=.*/TURN_SHARED_SECRET=$NEW/" .env
./deploy.sh
docker compose up -d

# 3. Update backend (whatever serves api.oneway.is)
#    Set TURN_SHARED_SECRET=$NEW in your secrets manager and redeploy.
#    Coordinate with step 2 — there's a brief window where outstanding
#    creds become invalid. Active calls already on the wire are unaffected.
```

### Rate limiting suggestions

The Express endpoint is a single HMAC + JSON encode per request — cheap.
Still, put it behind a generic per-IP rate limiter so a misbehaving client
can't burn your dyno:

```ts
import rateLimit from "express-rate-limit";
app.use("/api/turn-credentials", rateLimit({
  windowMs: 60_000,
  limit: 30,             // 30 requests/min/IP — way more than legit clients need
  standardHeaders: true,
  legacyHeaders: false,
}));
```

(That dependency isn't yet in the project; add it when you're ready to
deploy publicly.)

---

That's the full deployment surface. The only secrets you ever type are
`TURN_SHARED_SECRET` (once on the VPS, once on the backend) and the SSH
key. Everything else flows from those.
