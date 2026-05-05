# OneWay App Store first-pass review guide

Use this file as the source of truth when filling App Store Connect review notes.

## App summary

OneWay is a private communication app with:

- person-to-person voice and video calling
- incoming call experience powered by CallKit
- VoIP wake-up via PushKit for real incoming calls only
- contact discovery
- secure signaling and call setup

## Reviewer notes

Paste this into the App Review notes field:

```text
This app uses CallKit and PushKit strictly for real-time voice/video calls. VoIP pushes are used only to present incoming calls immediately. No background data or messaging is handled through PushKit.

Backend:
https://api.oneway.app

LiveKit is used for real-time communication.

Test account:
email: test@oneway.app
password: Test1234

Steps:
1. Open Calls tab
2. Tap contact
3. Accept incoming call on second device
```

## Required App Store Connect metadata

- Privacy Policy URL: `https://oneway.app/privacy`
- Support URL: `https://oneway.app/support`
- Marketing URL: `https://oneway.app`

## Required screenshots

- contacts list
- active video call screen
- incoming call screen
- settings/privacy screen

## Compliance checks before submission

1. Confirm incoming calls always surface CallKit.
2. Confirm VoIP pushes are sent only for actual incoming calls.
3. Confirm all production URLs use HTTPS / WSS.
4. Confirm there are no placeholder buttons or dead-end screens.
5. Confirm subscription purchase flows use Apple IAP if consumer-facing.
6. Confirm the privacy policy is published at the final public URL.
7. Confirm the storefront/feed can be browsed without blocking the reviewer behind an unusable login wall.
8. Confirm sample content or demo contacts exist so the reviewer can complete at least one meaningful flow.

## Known review risks

- If any paid in-app feature still routes to Stripe for consumers, App Review may reject under Apple's payment rules.
- If Push Notifications / VoIP capabilities are not enabled in signing, calling review will fail even if the code is correct.
- If the reviewer cannot complete a two-device call flow, the app may be rejected for incomplete functionality.
