# OneWay — PushKit, call history & voicemail

Two features landed together because they share plumbing (the call lifecycle
events the registry already emits).

- **PushKit** — incoming calls ring even when the app is killed.
- **Call history** — every terminal call is logged and exposed at
  `/api/history/*`.
- **Voicemail** — when the callee misses the ring, the caller can leave an
  audio voicemail; recipient listens via `AVAudioPlayer`.

The existing signalling, LiveKit, TURN, and CallKit pipelines are untouched.
`StubCallSignalingClient` and `StubCallService` still compile and behave
exactly as before.

## Files added or modified

### Backend (`server/src/`)

| Path                                  | Role                                                  |
| ------------------------------------- | ----------------------------------------------------- |
| `services/PushTokenStore.ts`          | File-backed `userId → voipToken` map                  |
| `services/VoIPPushService.ts`         | APNs HTTP/2 push via `apn`; lazy-loaded               |
| `routes/push.ts`                      | `POST/DELETE /api/push/register`                      |
| `services/CallHistoryService.ts`      | File-backed history log; both directions per call     |
| `services/VoicemailService.ts`        | Disk-backed audio + JSON metadata; S3-ready surface   |
| `routes/history.ts`                   | `GET /api/history/recent`, `:userId`, `call/:callId`  |
| `routes/voicemail.ts`                 | `POST /upload`, `GET /:userId`, `audio/:id`, `:id/listened` |
| `types/history.ts`                    | Wire types shared with iOS                            |
| `realtime/CallWebSocketServer.ts`     | New `onCallInvited` hook fires VoIP push              |
| `routes/calls.ts`                     | Same hook on REST `/invite`                           |
| `index.ts`                            | Wires history recording into `call:changed`           |
| `package.json`                        | Adds `apn`, `multer`, `@types/apn`, `@types/multer`   |

### iOS (`OneWay/`)

| Path                                             | Role                                       |
| ------------------------------------------------ | ------------------------------------------ |
| `Infrastructure/Push/VoIPPushManager.swift`      | Owns `PKPushRegistry`, decodes payloads    |
| `Infrastructure/Push/PushRegistryDelegate.swift` | `PKPushRegistryDelegate` shim              |
| `Infrastructure/Push/NetworkPushTokenRegistrar.swift` | POSTs tokens to `/api/push/register`  |
| `App/AppDelegate.swift`                          | Configures audio session + binds the push manager |
| `App/CipherChatApp.swift`                        | Adds `@UIApplicationDelegateAdaptor`       |
| `Domain/Models/ChatModels.swift`                 | `CallService.prepareIncomingCall(...)`     |
| `Infrastructure/Services/LiveKitCallService.swift` | Implements the new prep methods          |
| `Features/Calls/CallHistoryManager.swift`        | Pulls `/api/history/recent`                |
| `Features/Calls/VoicemailManager.swift`          | List, upload, play, mark-listened          |
| `Features/Calls/VoicemailRecorder.swift`         | `AVAudioRecorder`-backed recording         |
| `App/AppEnvironment.swift`                       | Constructs the new managers                |

## Required env (server)

```bash
# APNs (any one of token-auth or cert-auth)
APNS_BUNDLE_ID=com.onewayapp.OneWay
APNS_ENVIRONMENT=sandbox          # or "production"

# Token-auth (preferred — easier rotation):
APNS_KEY_ID=ABCD123456
APNS_TEAM_ID=ABCDEF7890
APNS_KEY_PATH=/etc/apns/AuthKey_ABCD123456.p8

# OR certificate auth:
# APNS_CERT_PATH=/etc/apns/cert.pem
# APNS_KEY_PEM_PATH=/etc/apns/key.pem
```

Without these the push service logs `[apn] no auth credentials set` and
becomes a no-op. The signalling backend still works (the WS `call:ringing`
event reaches a foregrounded app); only background wakeups are degraded.

## Required Xcode setup (one-time)

1. **Signing & Capabilities → +Capability** → add:
   - **Push Notifications**
   - **Background Modes** → check **Voice over IP**, **Audio, AirPlay, and Picture in Picture**, and **Background fetch**
2. **Info.plist** keys:
   ```
   NSMicrophoneUsageDescription   "OneWay needs the microphone for calls and voicemail."
   NSCameraUsageDescription       "OneWay needs the camera for video calls."
   ```
3. **APNs key** (token auth): in your Apple Developer account, create a Key
   with the **Apple Push Notifications service (APNs)** capability and download
   the `.p8`. Put the path in `APNS_KEY_PATH` on the server.
4. The bundle id used in `APNS_BUNDLE_ID` must match the one signing the
   build that registers the push token. The `.voip` topic is appended
   automatically.

## Wire flow on a real device

```
backend                     iPhone (background/killed)
  │                           │
  POST /api/calls/invite ────▶│
  ├─ CallRegistry: ringing
  ├─ ws push (ignored — app suspended)
  └─ VoIPPushService.send ───▶ APNs
                              │
                              ▼  (Apple wakes app)
                        PushRegistryDelegate
                              │
                              ▼
                        VoIPPushManager.handleIncomingPush
                          ├─ environment.callService.prepareIncomingCall(...)
                          └─ CallKitBridge.reportIncomingCall(...)
                              │  (CallKit UI shows up; phone rings)
                              ▼
                        user taps Accept
                              │
                        bridge.onAnswer ─▶ LiveKitCallService.answerCall
                              │
                              ├─ POST /api/calls/accept
                              ├─ POST /api/livekit/token
                              ├─ GET  /api/turn-credentials
                              └─ LiveKitTransport.connect(...)
```

When the user declines from the lock screen:
`bridge.onEnd → declineCall → POST /api/calls/decline`. The session never
contacts LiveKit.

## History flow

`CallRegistry` already fires `'call:changed'` on every status transition.
`index.ts` subscribes once:

```ts
callRegistry.on("call:changed", (call) => {
  if (isTerminal(call.status)) callHistory.recordFromSession(call);
});
```

Each terminated call writes **two** rows — outgoing for the caller, incoming
for the callee. The endpoints serve only the requesting user's view (auth
checked on every request).

| Status returned        | Cause                                               |
| ---------------------- | --------------------------------------------------- |
| `completed`            | `accepted` then either party hung up                |
| `declined`             | Callee tapped Decline                               |
| `missed`               | Ringing timeout (`CallRegistry.RING_TIMEOUT_MS = 45 s`) |
| `failed`               | LiveKit/transport never reached connected           |

## Voicemail flow

Triggered on the *caller* side after a missed call:

1. iOS sees a `call:ended` event with `reason: missed` (already wired in
   `LiveKitCallService.observeSignaling`).
2. UI presents a *Leave voicemail?* prompt.
3. `VoicemailRecorder.start()` records into a temp `m4a` file.
4. `VoicemailRecorder.stop()` returns the file URL.
5. `VoicemailManager.upload(callId:..., fileURL:..., mimeType:"audio/m4a")`
   POSTs `multipart/form-data` to `/api/voicemail/upload`.
6. Server stores audio under `uploads/voicemail/<id>.m4a` and metadata in
   `data/voicemails.json`. `attachVoicemail(callId, voicemailId)` patches
   the recipient's history row so the app can render a "voicemail attached"
   indicator.

The recipient lists voicemails via `GET /api/voicemail/:userId`, plays them
through `VoicemailManager.play(entry)` (downloads to a temp file then
`AVAudioPlayer.play`), and marks listened automatically.

### Storage

- `<server>/uploads/voicemail/` — audio files
- `<server>/data/voicemails.json` — metadata
- `<server>/data/call-history.json` — history log
- `<server>/data/push-tokens.json` — VoIP tokens

Move all four into S3 / Postgres later — every service exposes the same
`get/forUser/ingest` surface, so the swap is mechanical.

## Security checklist

| Threat                                       | Mitigation                                     |
| -------------------------------------------- | ---------------------------------------------- |
| Spoofed VoIP push from a third party         | Apple controls APNs; only your `.p8` can mint  |
| User registers another user's push token     | `req.userId` from auth, body trusted only for `voipToken` value |
| Token hijack (uninstall+reinstall)           | `set()` evicts any prior owner of the token    |
| Listening to someone else's voicemail        | `audio/:id` enforces `entry.calleeId === userId` |
| Spoofing the caller field on upload          | `callerId !== req.userId` → 403                |
| Oversized voicemail upload                   | multer `fileSize: 5 MB`, server clamps duration to 120 s |
| Disk-fill via repeated uploads               | (Add quota check before shipping; cheap to bolt on) |
| Missed-call "leak" via timing                | History endpoints scope to the auth'd user only |
| Caller reads recipient's other history rows  | `/api/history/:userId` requires `userId === auth user` |

## Dev testing checklist

PushKit + lifecycle:

```text
1. Build OneWay onto a real iPhone (PushKit does NOT work on Simulator).
2. Foreground the app once so didUpdate pushCredentials fires. Confirm in
   Xcode console: "[push] register" succeeds.
3. Verify on backend: server/data/push-tokens.json contains your userId.
4. Force-quit OneWay (swipe up). Send an invite from another device:
     curl -X POST -H 'Authorization: Bearer dev:<other-user>' \
          -H 'Content-Type: application/json' \
          -d '{"calleeId":"<your-user>","hasVideo":false}' \
          http://<lan>:3000/api/calls/invite
5. Phone rings on the locked screen. CallKit UI shows displayName + Accept/Decline.
6. Accept: app foregrounds, CallKit transitions to in-call UI, audio routes via LiveKit.
7. Decline: backend log shows POST /api/calls/decline → status declined.
8. WiFi → LTE: place a call on WiFi, then airplane-toggle WiFi. TURN's
   `mobility` plus LiveKit reconnect keep the call alive.
9. Multiple calls: place call A, hang up, immediately place call B from
    a different counterparty. Verify both rings reach you and history records both.
10. Missed-call timeout: ring without picking up. After 45 s the backend
    flips status to `missed`; both sides see a `call:ended` with reason missed.
```

Call history + voicemail:

```text
1. Place + accept a call, hang up. GET /api/history/recent shows a
   `completed` entry with non-zero `durationSeconds`.
2. Miss a call (let it ring out). Both users see a `missed` entry.
3. As the caller, record a 5–10 s voicemail with VoicemailRecorder, then
   upload via VoicemailManager.upload. Server returns 201 + voicemail id.
4. As the callee, GET /api/voicemail/<userId> lists the new voicemail.
5. Tap to play (VoicemailManager.play). AVAudioPlayer plays the file.
6. POST /api/voicemail/<id>/listened. Subsequent list shows `listened: true`.
7. Place several calls + voicemails. Restart the server. After restart,
   GET /api/history/recent and /api/voicemail/<userId> still return everything
   — they reload from data/*.json on boot.
```

## What to install (one shot)

```bash
cd server
npm install
# adds apn, ws, livekit-server-sdk, multer, @types/apn, @types/multer, @types/ws

# Optional smoke test of the APNs path against Apple's sandbox:
APNS_BUNDLE_ID=com.onewayapp.OneWay APNS_ENVIRONMENT=sandbox \
APNS_KEY_ID=... APNS_TEAM_ID=... APNS_KEY_PATH=./AuthKey.p8 \
npm run dev
# Then trigger an invite — `[apn] push failed` with `BadDeviceToken` confirms
# auth works (the token simply doesn't match the bundle).
```

In Xcode, after the new files appear via the project's
`PBXFileSystemSynchronizedRootGroup` auto-import, just build. The first
launch on a real device will fire `didUpdate pushCredentials` and ship the
token to `/api/push/register`.

## Things that didn't change

- `StubCallSignalingClient` and `StubCallService` are untouched — the new
  `prepareIncomingCall` requirement has a default no-op implementation in a
  protocol extension, so the stubs still satisfy the protocol.
- `LiveKitTransport`, `CallKitBridge`, `TurnCredentialsService` — same
  surface, same behavior.
- `NetworkCallSignalingClient` — same WebSocket + REST contract; voicemail
  uploads ride a separate path.
- `RootView`, `RootTab`, every existing tab/view — no UI changes required
  for this slice. (Adding a History tab is a follow-up.)
