# OneWay Launch Analytics Setup

This file documents the minimum crash and analytics setup for launch.

## iOS crash reporting

The app now includes a build-safe telemetry wrapper in:

- `/Users/king/Documents/OneWay/OneWay/OneWay/Infrastructure/Services/LaunchTelemetry.swift`

It always logs launch events through `os.Logger`, and it will automatically enable external SDKs when they are installed and configured.

### Sentry iOS

Add the Swift package in Xcode:

- `https://github.com/getsentry/sentry-cocoa`

Then add this Info.plist key:

```xml
<key>OneWaySentryDSN</key>
<string>YOUR_SENTRY_DSN</string>
```

At app launch, `LaunchTelemetry.shared.configure()` will start Sentry automatically when this key is present.

## iOS analytics

Add the Swift package in Xcode:

- `https://github.com/firebase/firebase-ios-sdk`

Recommended products:

- `FirebaseAnalytics`

After Firebase is installed and configured with `GoogleService-Info.plist`, the telemetry wrapper will automatically call Firebase Analytics for the tracked events.

## Backend crash reporting

Recommended package:

```bash
npm install @sentry/node
```

Recommended setup in `/Users/king/Documents/OneWay/OneWay/server/src/index.ts`:

```ts
import * as Sentry from "@sentry/node";

Sentry.init({
  dsn: process.env.SENTRY_DSN,
  tracesSampleRate: 1.0,
});
```

Add:

```env
SENTRY_DSN=
```

to your production environment.

## Launch events currently wired in iOS

- `app_launch`
- `call_started`
- `call_failed`
- `call_ended`
- `store_viewed`
- `storefront_load_failed`
- `product_clicked`
- `checkout_tapped`
- `paywall_shown`

## Launch dashboard priorities

Track these first:

- call success rate
- call failure rate by network / build cohort
- storefront view to product click rate
- product click to checkout tap rate
- day-1 retention
- crash-free users
