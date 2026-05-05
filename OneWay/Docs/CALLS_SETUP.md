# OneWay calls — one-time Xcode setup

Voice/video calls in OneWay are split into three pieces so each can be swapped
without touching the others:

| Piece            | What it does                                       | File                                          |
| ---------------- | -------------------------------------------------- | --------------------------------------------- |
| `CallKitBridge`  | iOS system call UI (lock-screen, recents, audio)   | `Infrastructure/Services/CallKitBridge.swift` |
| `CallTransport`  | WebRTC stack (mic/camera/peer connection)          | `Domain/Services/CallTransport.swift`         |
| `CallSignalingClient` | Ring/answer/hangup against your backend       | `Domain/Services/CallTransport.swift`         |

`LiveKitCallService` composes all three and conforms to the existing
`CallService` protocol — it's a drop-in replacement for `StubCallService`.

The default build still uses `StubCallService`. The real path activates
automatically once the LiveKit SwiftPM package is added.

## 1. Add the LiveKit Swift package

1. Open `OneWay.xcodeproj`.
2. **File → Add Package Dependencies…**
3. Paste:
   ```
   https://github.com/livekit/client-sdk-swift
   ```
4. Pick the latest stable version, add the **LiveKit** product to the
   `OneWay` app target, and finish.

Once the package resolves, `#if canImport(LiveKit)` flips on in:

- `Infrastructure/Services/LiveKitTransport.swift` — real `Room`-backed transport.
- `App/AppEnvironment.swift` — `callService` becomes `LiveKitCallService`.

No project-file edits are needed; the project uses
`PBXFileSystemSynchronizedRootGroup`.

## 2. Info.plist

Add the keys below (Project → Targets → OneWay → Info). The first two are
required for the system call UI; the rest are required by Apple's privacy
prompts and the WebRTC stack.

| Key                              | Type     | Value                              |
| -------------------------------- | -------- | ---------------------------------- |
| `UIBackgroundModes`              | Array    | `voip`, `audio`                    |
| `NSMicrophoneUsageDescription`   | String   | "OneWay uses your microphone for calls." |
| `NSCameraUsageDescription`       | String   | "OneWay uses your camera for video calls." |

## 3. Capabilities & entitlements

In **Signing & Capabilities**, add:

- **Background Modes** → check *Voice over IP* and *Audio, AirPlay, and Picture in Picture*.
- **Push Notifications** (only if you implement PushKit/VoIP wakes — see §5).

CallKit itself does not need a separate capability.

## 4. Token server

LiveKit clients can never talk directly to a LiveKit cloud project with the
project secret — every join needs a short-lived JWT minted server-side.

`StubCallSignalingClient` returns a fake token so the app compiles end-to-end,
but no media will actually flow until you stand up:

- An endpoint that mints a LiveKit JWT (room name + identity + grants).
- A real `CallSignalingClient` that calls it.

For OneWay, the obvious home for that endpoint is the existing Express server
under `server/` — drop in `/api/calls/invite|accept|decline|hangup`. Then
swap `StubCallSignalingClient` for a `NetworkCallSignalingClient` in
`AppEnvironment.live`.

## 5. Incoming calls (PushKit)

The current sketch only handles outbound calls cleanly. To accept calls when
the app is suspended, you need PushKit + a VoIP push from your backend:

1. Register a `PKPushRegistry` for `.voIP` at app launch.
2. On `didReceiveIncomingPushWith`, call
   `CallKitBridge.shared.reportIncomingCall(uuid:handle:hasVideo:)`
   **before** the push completion handler returns — Apple kills the app
   otherwise.
3. The user's tap on the system call screen routes through
   `CXAnswerCallAction` → `CallKitBridge.onAnswer` → `LiveKitCallService.answerCall`.

## 6. Regional caveat

CallKit is not available in mainland China. Wrap the bridge in a runtime
region check (or feature flag) and fall back to in-app call UI there. The
`CallTransport` half still works fine — only the system UI piece needs
swapping.

## 7. What's wired so far

```
OneWay/
├── Domain/Services/CallTransport.swift          # CallTransport, CallSignalingClient, CallCredentials
└── Infrastructure/Services/
    ├── CallKitBridge.swift                      # CXProvider wrapper (always compiled)
    ├── LiveKitTransport.swift                   # #if canImport(LiveKit)
    ├── StubCallSignalingClient.swift            # always-compiled dev signalling
    ├── LiveKitCallService.swift                 # composes the three above
    └── StubCallService.swift                    # the default until LiveKit is added
```

`AppEnvironment.live` chooses between `LiveKitCallService` and
`StubCallService` based on `canImport(LiveKit)`. No other code paths need to
change to flip the app onto real calls.
