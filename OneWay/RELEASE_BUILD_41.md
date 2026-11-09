# OneWay 2.0 — build 41 source snapshot

This branch records the native iOS application and supporting server source used during the current OneWay integration work. It includes the sculpted violet icon system, Quantum home/toolbox integration, signup suggestions, shop/site flow integration, metallic Chirp push-to-talk control and haptics, metallic phone keypad, larger unframed Chirp Contacts/Requests icons, Shops-to-Quantum home navigation and the softer satin keypad finish.

## Validation already completed

- Signed iPhone build 41 succeeded and was installed in place on the two authorized test iPhones.
- Native keypad captures passed in empty and entered-number states at 390x844 and 430x932.
- Quantum home navigation checks passed, preserving open websites and reusing a home tab.
- Earlier integration checks covered signup autofill, toolbox persistence, app shortcut preferences and shop/site linking.
- These checks do not establish full end-to-end call, payment or public server readiness.

## Building the native app

Open `OneWay.xcodeproj` from this directory. The checked-in `Vendor/LiveKit` package is the local SDK source referenced by the project; keep its license and third-party notices.

Generated Rust libraries, local signing material and runtime credentials are intentionally excluded. With the pinned Rust toolchain and Apple targets available, build the admission libraries from this directory before building Xcode:

```sh
ALT2_BUILD_ROOT=/private/tmp/oneway-rust-build bash SecurityPrototypes/VodozemacAdmission/Scripts/build_rust.sh
```

The script builds the stable and full variants and creates the required `SecurityPrototypes/VodozemacAdmission/Artifacts/` outputs. It expects fresh output paths for generated XCFrameworks. Configure your own Apple development team/signing and server environment separately; no credentials are included in this snapshot.

The server implementation lives in `server/`. Install its locked dependencies and configure its runtime environment before using it. This GitHub push does not deploy that server code, upload to App Store Connect, or publish an App Store update.
