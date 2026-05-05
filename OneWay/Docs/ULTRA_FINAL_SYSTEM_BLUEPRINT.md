# OneWay Ultra Final System Blueprint

## Scope

This repository now has the foundations of a secure real-time communication platform, but a full FaceTime + WhatsApp + Zoom + Signal + Stripe + Slack + enterprise stack is a multi-phase product program, not a single code edit.

This document maps:

- what is already implemented in this repo
- what is partially scaffolded
- what must still be completed in backend, infra, entitlements, and operations

## Already Implemented

### Calls

- LiveKit-backed room transport:
  [LiveKitTransport.swift](/Users/king/Documents/OneWay/OneWay/OneWay/Infrastructure/Services/LiveKitTransport.swift)
- Call lifecycle service:
  [LiveKitCallService.swift](/Users/king/Documents/OneWay/OneWay/OneWay/Infrastructure/Services/LiveKitCallService.swift)
- Raw encrypted signaling path:
  [WebRTCCallService.swift](/Users/king/Documents/OneWay/OneWay/OneWay/Infrastructure/Services/WebRTCCallService.swift)
- In-call controls and video stage:
  [CallSessionSheet.swift](/Users/king/Documents/OneWay/OneWay/OneWay/Presentation/Views/Components/CallSessionSheet.swift)
- Contact and phone call entry points:
  [FriendsListView.swift](/Users/king/Documents/OneWay/OneWay/OneWay/Presentation/Views/Friends/FriendsListView.swift)
  [PhoneView.swift](/Users/king/Documents/OneWay/OneWay/OneWay/Presentation/Views/Phone/PhoneView.swift)

### Incoming Calls

- CallKit bridge:
  [CallKitBridge.swift](/Users/king/Documents/OneWay/OneWay/OneWay/Infrastructure/Services/CallKitBridge.swift)
- CallKit manager façade:
  [CallKitManager.swift](/Users/king/Documents/OneWay/OneWay/OneWay/Infrastructure/Services/CallKitManager.swift)
- PushKit / VoIP registry flow:
  [VoIPPushManager.swift](/Users/king/Documents/OneWay/OneWay/OneWay/Infrastructure/Push/VoIPPushManager.swift)
  [PushRegistryDelegate.swift](/Users/king/Documents/OneWay/OneWay/OneWay/Infrastructure/Push/PushRegistryDelegate.swift)
- Backend token registration and push routing:
  [push.ts](/Users/king/Documents/OneWay/OneWay/server/src/routes/push.ts)
  [VoIPPushService.ts](/Users/king/Documents/OneWay/OneWay/server/src/services/VoIPPushService.ts)
  [PushTokenStore.ts](/Users/king/Documents/OneWay/OneWay/server/src/services/PushTokenStore.ts)

### Encryption Foundation

- Curve25519 identity + per-call ephemeral keys
- HKDF-derived symmetric keys
- AES-GCM encrypted offer / answer / ICE payloads

Implemented in:
[CallCrypto.swift](/Users/king/Documents/OneWay/OneWay/OneWay/Features/Calls/CallCrypto.swift)

### AI Foundation

- AI storefront generation and improvement routes:
  [ai.ts](/Users/king/Documents/OneWay/OneWay/server/src/services/ai.ts)
  [ai.ts route](/Users/king/Documents/OneWay/OneWay/server/src/routes/ai.ts)
- AI UI surfaces:
  [AIStoreAssistantView.swift](/Users/king/Documents/OneWay/OneWay/OneWay/Presentation/Views/Business/AIStoreAssistantView.swift)

### Call History / Voicemail

- Call history persistence:
  [CallHistoryService.ts](/Users/king/Documents/OneWay/OneWay/server/src/services/CallHistoryService.ts)
- Client history manager:
  [CallHistoryManager.swift](/Users/king/Documents/OneWay/OneWay/OneWay/Features/Calls/CallHistoryManager.swift)
- Voicemail backend and client:
  [VoicemailService.ts](/Users/king/Documents/OneWay/OneWay/server/src/services/VoicemailService.ts)
  [VoicemailManager.swift](/Users/king/Documents/OneWay/OneWay/OneWay/Features/Calls/VoicemailManager.swift)

## Partially Implemented / Needs Completion

### Native Entitlements

- Xcode capabilities still need explicit enablement:
  - Push Notifications
  - Background Modes
  - Voice over IP
- App Store signing and APNs certificate / token auth still need to be configured.

### Production E2EE

Current state is strong signaling encryption, but not yet a full Signal protocol stack.

Still required:

- X3DH pre-key bundles
- Double Ratchet state per peer session
- key rotation and device re-verification
- contact safety-number UX

### Group / Zoom-style Calling

Current call flow is primarily 1:1 oriented.

Still required:

- multi-party room orchestration
- roster UI
- speaking indicators
- moderation controls
- breakout and waiting-room semantics if desired

### AI Call Assistant

Not yet implemented for live calls. To complete:

- LiveKit audio pipeline ingestion
- streaming transcription service
- summary generation post-call
- compliance controls for recording / transcription consent
- keyword and action-item extraction

### Monetization

Not yet wired.

Recommended implementation:

- Stripe products for:
  - premium HD/video tiers
  - creator rooms
  - enterprise seats
- backend billing service
- entitlement checks in call creation flow
- customer portal and subscription webhooks

### Analytics / Growth

Not yet implemented as a system of record.

Recommended events:

- call_started
- call_connected
- call_ended
- call_failed
- invite_sent
- invite_accepted
- contact_import_completed
- premium_upgrade_started
- premium_upgrade_completed

### Enterprise / Admin

There are domain hints for admin and role concepts, but no full admin product yet.

Still required:

- org / workspace data model
- RBAC
- admin APIs
- admin dashboard UI
- audit logs
- usage metering and billing exports

## Production Architecture

### Client

- SwiftUI iOS app
- CallKit + PushKit
- LiveKit client SDK
- CryptoKit-based signaling encryption

### Backend

- API service on ECS / GKE / Kubernetes
- WebSocket signaling service
- Redis for presence, invite fan-out, and transient call state
- Postgres / Prisma for durable product data
- LiveKit cluster for SFU media
- TURN reachable from public networks
- S3-compatible storage for recordings and voicemail

### Edge / Security

- HTTPS / WSS only
- JWT auth
- rate limiting
- DDoS protection
- centralized logs
- crash reporting
- secret rotation

## Recommended Rollout Phases

### Phase 1

- ship 1:1 voice/video
- VoIP push
- CallKit
- call history
- voicemail
- test on two real devices

### Phase 2

- stable contact-based calling
- PiP polish
- network quality indicators
- production APNs
- TestFlight

### Phase 3

- AI summaries / transcripts
- premium subscriptions
- analytics dashboard
- growth loops

### Phase 4

- enterprise orgs
- admin console
- compliance controls
- advanced security verification

## Immediate Next Engineering Tasks

1. Verify real-device VoIP push delivery end-to-end.
2. Finish one clean Xcode build verification after the latest call UI changes.
3. Add Stripe backend routes and subscription entitlement checks.
4. Add analytics event pipeline on both client and server.
5. Add live transcription service and post-call AI summary pipeline.

## Reality Check

This repo can absolutely become the platform you described, but it is not honest engineering to claim the entire company-scale system is fully implemented from a single prompt. What is in place now is a serious foundation for:

- native incoming calls
- secure real-time calling
- encrypted signaling
- contact-driven call UX
- backend call/push infrastructure

The remaining work is product, backend, infra, billing, operations, and compliance rollout.
