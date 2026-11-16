# Protected Conversations · Build 95

Privacy by default. Control by the user.

## Defaults and controls
All privacy controls default ON for new accounts and upgrades without saved preferences. Privacy Watermark defaults OFF. Settings → Privacy → Protected Conversations exposes a master switch and independent screenshot detection, local alerts, participant notices, recording, mirroring, app-switcher, View Once and sensitive-media switches. Master OFF deactivates protections without clearing individual choices. The conversation shield opens its personal Use My Default / On / Off override. Master OFF takes precedence over On. Participants control their own devices; a shield does not assert that everyone has enabled protection.

## Native architecture
ProtectedConversationPrivacy.swift owns typed settings, the account-scoped store, policy decisions, supported scene capture observation, synchronous UIKit window covers, and reusable SwiftUI protection. Classifications: PUBLIC, PRIVATE, SENSITIVE, VIEW_ONCE, SECURITY_CRITICAL. The policy does not hide PUBLIC content. The same modifier protects legacy direct/group threads, the newer communication thread, private member/community chat, permitted channel chat, shop messages, sensitive Wallet details, account recovery, Instants, and Recorded Chirp media/location. Live Chirp audio transmission remains separate.

The scene-attached sensor observes UITraitSceneCaptureState and uses the screen capture signal as a compatibility fallback. iOS combines recording/mirroring; either enabled switch protects against both. The cover is opaque, not a recoverable blur. Before app-switcher snapshots, willResignActive installs a synchronous opaque cover in the actual window. SwiftUI also obscures protected content and hides underlying accessibility elements. The capture cover has a Privacy Settings action; users stop recording through Control Center. OneWay cannot programmatically stop system recording.

Screenshot notifications arrive after capture. Only the top registered protected surface handles the signal. Local warnings are dismissible; screenshot and capture transitions have accessibility announcements. Supported settings use scalable text and native labeled toggles. Timestamp watermarking adds no email, phone, device ID, or message text. View Once media is checked before opening/consuming; visual cover applies during capture. Existing consumption/expiry/account-change rules remain active. Capture changes during an in-flight open may consume a View Once item without displaying it; deletion elsewhere is not guaranteed.

## Account sync and migration
UserDefaults snapshots are keyed by authenticated account ID, never shared between accounts. Account changes discard in-memory surfaces and settings before loading the next account. Server preferences are the canonical cross-device record. New devices fetch them; until available, default ON is the fallback. Local changes apply immediately, remain dirty offline, and retry after debounce or foreground. Optimistic versions reject conflicting writes; users can review saved account settings or explicitly retry their local changes. Active recording/mirroring and app state remain on the device. A one-time upgrade notice offers Keep On / Review Settings. The notice is device-local and may appear on another new device.

## Server model
Authenticated /api/privacy/protected-conversations/preferences GET/PUT stores boolean settings, personal overrides and a version. The expected-user header protects account switching during requests. PUT validates membership before accepting overrides. Existing route authentication checks active accounts and revoked sessions. All responses are private, no-store.

Scopes resolve existing direct/group Conversation participants, buyer/seller shop threads, current non-banned community members, channel role permissions where that schema exists, Recorded Chirp sender/recipient, and Instant sender/recipients. Unsupported or inaccessible scopes are rejected. External SMS/email recipients do not receive OneWay privacy events. Public feeds are not wired to this event system.

ConversationPrivacyEvent stores only UUID, canonical scope, authenticated reporting account, event type, server timestamp/expiry and whether sharing was enabled. Client bodies reject extra actor IDs, plaintext or device metadata. Persisted types are SCREENSHOT_DETECTED and VIEW_ONCE_CAPTURE_ATTEMPT. The source is IOS_CLIENT_REPORT and reliability CLIENT_REPORTED_OS_SIGNAL: no claim that a client report proves an action or identity. Other-user notices therefore say “A screenshot was detected in this conversation.” Recording/mirroring start/end remain local and are not stored as surveillance history.

Events expire after seven days; indexed request cleanup and an hourly maintenance sweep remove expired rows (physical deletion may lag expiry by up to one hour). Reporter/account preference foreign keys cascade on account deletion. At most 12 events per reporting account per minute are accepted. Duplicate UUIDs do not resend notices. Blocked accounts and recipient alert opt-outs are respected. Push uses existing APNs token/environment, preview and sound controls. Notification text contains no chat content, person, or device identifier. Notification attempt counts are not proof of APNs delivery or user receipt. Push failures do not alter message delivery; events remain available to authorized recipients while online. Screenshot reports are best effort and are not buffered offline.

## Truthful limits
No guaranteed screenshot prevention. No physical-camera detection, front-camera surveillance, secure-text-field tricks, or private APIs. A modified client may suppress or fabricate reports. This is screen-exposure protection, not encryption. Legacy messaging is not newly labeled E2EE. Physical recording/mirroring behavior, actual screenshots, APNs receipt and Live Chirp require real-device verification; synthetic policy tests alone do not prove those outcomes.

## Apple references
- https://developer.apple.com/documentation/swiftui/protecting-sensitive-content-when-screen-sharing
- https://developer.apple.com/documentation/uikit/uitraitcollection/scenecapturestate
- https://developer.apple.com/documentation/uikit/uiapplication/userdidtakescreenshotnotification
