# OneWay signalling — developer guide

End-to-end picture of the call lifecycle, the wire protocol, and the local
testing checklist.

## Architecture

```
iPhone A                   Backend (server/)              iPhone B
  │                            │                             │
  │ POST /api/calls/invite ───▶│                             │
  │                            │ (CallRegistry: ringing)     │
  │                            │ ws push: call:ringing ─────▶│
  │                            │                             │ CallKit ringing UI
  │                            │ POST /api/calls/accept ◀────│
  │                            │ (CallRegistry: accepted)    │
  │ ws push: call:accepted ◀───│                             │
  │ POST /api/livekit/token ─▶ │                             │ POST /api/livekit/token
  │ (mint JWT)                 │                             │ (mint JWT)
  │                                                          │
  │           ──── LiveKit room (media via TURN) ────         │
```

REST and WebSocket share the same `CallRegistry` so a client can fall back
to one if the other breaks.

## Backend env vars

Add to `server/.env`:

```bash
# WebSocket / REST share the same HTTP port (default 3000).
PORT=3000
DEFAULT_DEV_USER_ID=00000000-0000-0000-0000-000000000000

# LiveKit token mint. Without these, /api/livekit/token returns
# obviously-fake tokens and the iOS connect step will fail loudly.
LIVEKIT_URL=wss://your-livekit-host
LIVEKIT_API_KEY=...
LIVEKIT_API_SECRET=...

# Same shared secret as turnserver.conf's static-auth-secret.
TURN_SHARED_SECRET=...
TURN_HOSTNAME=turn.oneway.app
```

Install the new packages once per repo:

```bash
cd server
npm install
# adds: ws, livekit-server-sdk, @types/ws
```

## REST surface

All routes require auth. Dev format:
`Authorization: Bearer dev:<userId>` or `X-Dev-User-Id: <userId>`.

| Method | Path                       | Body / Notes                           |
| ------ | -------------------------- | -------------------------------------- |
| POST   | `/api/calls/invite`        | `{ calleeId, hasVideo }` → `201 { call }` |
| POST   | `/api/calls/accept`        | `{ callId }` (callee only)             |
| POST   | `/api/calls/decline`       | `{ callId }` (callee only)             |
| POST   | `/api/calls/hangup`        | `{ callId }` (any participant)         |
| GET    | `/api/calls/active`        | → `{ calls: [...] }` for the caller    |
| GET    | `/api/calls/:callId`       | (participant only)                     |
| POST   | `/api/livekit/token`       | `{ roomName }` → `{ url, token, roomName }` |

Identity inside the JWT is always the authenticated user — body
`identity` is ignored. Room names are sanitized (`[a-z0-9_\-:.]`, ≤ 64 chars).

## WebSocket protocol

`wss://api.oneway.app/ws/calls` (or `ws://` in dev).

### Frame shape

```json
{ "type": "<event>", "payload": { ... } }
```

### Client → server

| Event              | Payload                                   |
| ------------------ | ----------------------------------------- |
| `auth`             | `{ token: "dev:<userId>" }` — first frame, mandatory |
| `call:invite`      | `{ callId, calleeId, hasVideo }`          |
| `call:accept`      | `{ callId }`                              |
| `call:decline`     | `{ callId }`                              |
| `call:hangup`      | `{ callId }`                              |
| `call:ice-ready`   | `{ callId }` (informational, server replies with `call:state`) |
| `presence:update`  | `{ online: boolean }`                     |

### Server → client

| Event              | Payload         | When                                       |
| ------------------ | --------------- | ------------------------------------------ |
| `call:ringing`     | `{ call }`      | Counterparty just placed the call          |
| `call:accepted`    | `{ call }`      | Callee accepted (sent to caller)           |
| `call:declined`    | `{ call }`      | Callee declined (sent to caller)           |
| `call:ended`       | `{ call }`      | Either side hung up / call ended / missed  |
| `call:state`       | `{ call }`      | After reconnect — replays current state    |
| `presence:online`  | `{ userId }`    | Counterparty connected                     |
| `presence:offline` | `{ userId }`    | Counterparty disconnected                  |
| `error`            | `{ code, message }` | Last action was rejected               |

## Security guarantees

| Threat                                  | Mitigation                                      |
| --------------------------------------- | ----------------------------------------------- |
| Forged caller identity                  | `req.userId` derived from auth token, never body |
| Accepting someone else's call           | `call.calleeId === userId` check on accept/decline |
| Hanging up a call you're not in         | `isParticipant` check on hangup                 |
| Joining an arbitrary LiveKit room       | `/api/livekit/token` checks `findByRoom`         |
| Invite spam                             | Per-user token bucket (20/min, configurable)    |
| Long-ringing zombie calls               | 45-second timeout → status flips to `missed`    |
| Replay of stale auth                    | WS auth re-required on reconnect; tokens hold no session state on disk |

## Dev testing checklist

Two devices, one backend.

```text
1. Start backend
   cd server && npm install && npm run dev
   → "[Server] Listening on 0.0.0.0:3000"
   → "[Server] WebSocket: ws://<lan-ip>:3000/ws/calls"

2. Build the iOS app on the simulator (User A) AND on a physical iPhone (User B).
   Both pointed at the same backend. Confirm in console:
     [API] Using base URL: http://<lan-ip>:3000

3. (Optional) Note the per-install identity for each device:
     UserDefaults["OneWay.LocalUserID"]
   You'll need both UUIDs to invite the right side.

4. From User A, place a call to User B. From the Phone tab → New call →
   paste User B's UUID into the chatID field (or pre-seed it in dev).
   Backend log:  POST /api/calls/invite  →  201
                 [registry] call <uuid> ringing

5. Within 1 s on User B: CallKit incoming-call screen appears.
   If the screen does NOT appear, check:
     - WebSocket connected? Console: "[Signaling] auth ok"
     - LiveKit package installed? `LiveKitCallService` is the active service?

6. On User B, tap Accept. Backend log:
     POST /api/calls/accept  →  200
   Both devices then hit POST /api/livekit/token. Both join the LiveKit room.

7. Verify both joined: User A sees a participant tile for User B and vice
   versa. ICE selected pair in Xcode console should show `relay/...` if
   the network is symmetric NAT (TURN engaged).

8. From either side, tap Hangup. Backend log:
     POST /api/calls/hangup  →  200  (status: ended)
   Both devices' UIs return to idle.

9. Decline path: place a fresh call, on User B tap Decline.
   Backend log:  POST /api/calls/decline  →  200  (status: declined)
   User A sees a `call:declined` event and the UI returns to idle.

10. Missed-call timeout: place a call from User A, do nothing on User B.
    After 45 s, backend log: "[registry] <uuid> ringing → missed".
    Both UIs return to idle, User A sees a `call:ended` event with reason
    `missed`.

11. WiFi → cellular handoff with TURN: place a call on WiFi, then airplane-
    mode the WiFi off (LTE keeps audio). The TURN `mobility` flag plus the
    LiveKit reconnect logic should keep the call alive within ~5 s.
    Confirm in turnserver.log: `... mobility ticket received ...`
```

## What did NOT change

- `StubCallSignalingClient` is still present and selected automatically when
  the LiveKit SDK isn't installed. The new `CallSignalingClient.incomingEvents`
  requirement is satisfied by an empty stream — existing call sites compile.
- TURN credential plumbing, CallKit bridge, `LiveKitTransport`, and
  `LiveKitCallService`'s public surface are unchanged. The composition root
  (`AppEnvironment.live`) is the only place that picks the network signaling
  client over the stub.

## Compile / install notes

- The backend uses `require("ws")` and `require("livekit-server-sdk")` inside
  try/catch so the project still **compiles and runs** before
  `npm install` adds the new dependencies — at boot you'll see warnings:

  ```
  [ws] `ws` package not installed. WebSocket signalling disabled.
  [LiveKit] livekit-server-sdk not installed. Stub tokens will be issued.
  ```

  Both warnings disappear after `npm install`.

- The Swift `NetworkCallSignalingClient` is an `actor`, so it satisfies
  `CallSignalingClient: Sendable` automatically. `incomingEvents` is
  declared `nonisolated` so non-actor-isolated callers (the
  `LiveKitCallService` MainActor) can read it without an `await`.

- Because `WSLike` / `WSServerLike` are local interfaces in
  `CallWebSocketServer.ts`, the file typechecks even before `@types/ws`
  installs. You can remove the local interfaces and replace with imports
  once the package is in.
