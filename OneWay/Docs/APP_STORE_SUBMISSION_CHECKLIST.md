# OneWay App Store submission checklist

## Product compliance

- [ ] Incoming calls show real CallKit UI
- [ ] Accept, decline, and end-call actions work
- [ ] VoIP pushes are used only for incoming calls
- [ ] No marketing or analytics traffic uses PushKit
- [ ] Consumer subscriptions use Apple IAP, not Stripe
- [ ] Permission strings clearly explain microphone and camera usage
- [ ] Guest browsing or demo content is available if login is not immediately usable for review

## Metadata

- [ ] App description updated
- [ ] Privacy Policy URL set to `https://oneway.app/privacy`
- [ ] Support URL added
- [ ] Keywords, subtitle, and category finalized
- [ ] Review notes pasted from `Docs/APP_STORE_REVIEW_GUIDE.md`

## Reviewer access

- [ ] Test account created: `test@oneway.app`
- [ ] Password verified: `Test123!`
- [ ] Review instructions tested exactly as written
- [ ] Second-device review setup available

## Technical validation

- [ ] Production API uses `https://api.oneway.is`
- [ ] Production LiveKit uses `wss://rtc.oneway.app`
- [ ] TURN hostname uses `turn.oneway.app`
- [ ] Push Notifications capability enabled in Xcode target
- [ ] Background Modes includes VoIP and remote notifications only where needed
- [ ] APNs production key uploaded in App Store Connect / backend
- [ ] `OneWayAPIBaseURL` override removed before production submission unless the custom domain is still intentionally not live
- [ ] `OneWaySentryDSN` configured if Sentry release monitoring is enabled

## Functional testing

- [ ] App launches cleanly on fresh install
- [ ] Login succeeds
- [ ] Storefront/feed loads with real or demo content
- [ ] Contact list loads
- [ ] Outgoing call connects on Wi-Fi
- [ ] Outgoing call connects on cellular
- [ ] Incoming call appears while app is foregrounded
- [ ] Incoming call appears while app is backgrounded
- [ ] Incoming call appears while app is terminated
- [ ] Audio works on both sides
- [ ] Video works on both sides
- [ ] Hang up updates both devices cleanly
- [ ] No empty/broken screens remain in primary reviewer flows

## Launch instrumentation

- [ ] Sentry iOS package added if crash reporting is desired for launch
- [ ] Firebase Analytics package added if production analytics is desired
- [ ] `call_started`, `call_ended`, `store_viewed`, `product_clicked`, and `paywall_shown` events verified in debug logs or analytics dashboards

## Submission

- [ ] Archive created in Xcode
- [ ] Build uploaded to App Store Connect
- [ ] Export compliance answered
- [ ] Screenshots uploaded
- [ ] Privacy nutrition labels completed
- [ ] Submit for review
