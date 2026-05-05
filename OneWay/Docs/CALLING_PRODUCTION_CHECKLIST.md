# OneWay Calling Production Checklist

## Client

- Add the `Push Notifications` capability in Xcode.
- Enable `Background Modes` with `Voice over IP`, `Audio`, and `Remote notifications`.
- Verify `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` are present.
- Test CallKit accept, decline, mute, speaker, camera disable, and camera flip on device.
- Test incoming VoIP push while the app is foregrounded, backgrounded, and terminated.

## Security

- Keep using Curve25519 + HKDF + AES-GCM for encrypted signaling.
- Replace the current TOFU signaling bootstrap with X3DH for first-contact setup.
- Add Double Ratchet session rotation for post-setup message and signaling secrecy.
- Issue short-lived JWTs from the backend only.
- Require HTTPS/WSS in production.

## Backend

- Run the API behind a load balancer.
- Use Redis for presence, ringing fan-out, and transient call state.
- Run LiveKit in a clustered deployment.
- Keep TURN reachable on public IPs for NAT traversal.
- Store recordings or call artifacts in S3-compatible object storage if enabled.
- Send APNs VoIP pushes when a callee is offline or the app is suspended.

## App Store Readiness

- Add privacy policy and data-use disclosures.
- Verify signing entitlements for push and background modes.
- Run TestFlight on at least two physical devices.
- Validate incoming-call flow with the app force-quit.
