# OneWay Group Testing Checklist

## Build + Signing
- Open `/Users/king/Documents/OneWay/OneWay/OneWay.xcodeproj` in Xcode.
- Target `OneWay` -> `Signing & Capabilities`:
  - Team: your Apple Developer team
  - Bundle ID: `com.king.OneWay` (or your final ID)
  - Signing: Automatic
- Product -> Clean Build Folder, then run on a physical device.

## Versioning
- Target `OneWay` -> General:
  - Version (`MARKETING_VERSION`): `1.0`
  - Build (`CURRENT_PROJECT_VERSION`): increment before each test drop.

## Permissions (already configured)
- Contacts
- Camera
- Photo Library
- Microphone

## Core Regression Pass
1. Onboarding: all 5 screens, final `Get Started`.
2. Tabs: reorder by long-press drag; app restart keeps order.
3. Updates:
   - Post text/photo/video story.
   - Story appears in Updates status bubble.
   - Story opens from Settings profile image tap.
4. Chats:
   - Open thread, send mock message, camera attach flow opens.
   - Top-left menu (`Select chats`, `Read all`) is visible/functional.
5. Calls:
   - `+` opens New Call picker.
   - `Schedule`, `Keypad`, `Favorites` screens open and actions work.
6. Contacts import:
   - Permission prompt appears.
   - Imported contacts persist after relaunch.
7. Settings:
   - No top-right dots/QR.
   - Profile photo upload/take photo works.

## Known Local CLI Build Limitation
- `xcodebuild` in this environment can fail from local CoreSimulator/provisioning service permissions.
- Use Xcode GUI on your Mac for final archive/install validation.

## Pre-Invite Group Testers
- Add tester notes with known mock/stub behavior (encryption/calls backend are scaffolded).
- Provide a short test script (10-15 minutes) + bug report template:
  - Device model + iOS version
  - Steps to reproduce
  - Expected vs actual
  - Screenshot/screen recording
