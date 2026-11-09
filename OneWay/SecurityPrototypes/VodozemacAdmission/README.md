# ALT-2 isolated iOS admission

This is an evaluation, not an approved production cryptosystem. Only the
dedicated `VodozemacAdmission` scheme/targets in the real `OneWay.xcodeproj`
compile this code. Existing application targets do not depend on it.

The Rust crate forbids unsafe source code and wraps pinned vodozemac APIs using
UniFFI 0.32.1. Generated Swift calls are contained behind `OneWayE2EEEngine`.
Stable and experimental-full-tag native libraries are separate artifacts.
`Evidence/pin-and-artifacts.json` records exact pins and artifact hashes.

Build from the repository root with Rust 1.89.0 and Xcode 26.6:

```sh
export ALT2_BUILD_ROOT=/absolute/disposable/build-directory
bash SecurityPrototypes/VodozemacAdmission/Scripts/build_rust.sh
xcodebuild test -project OneWay.xcodeproj -scheme VodozemacAdmission \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_UUID' \
  -derivedDataPath /absolute/disposable/DerivedStable
xcodebuild test -project OneWay.xcodeproj -scheme VodozemacAdmission \
  -configuration Release ALT2_MODE=full \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_UUID' \
  -derivedDataPath /absolute/disposable/DerivedFull
```

The checked-in project already contains integration. `Scripts/integrate.rb`
documents/recreates the additive project change only on a copy without those
targets; it refuses duplicates. Ruby xcodeproj 1.28.1 was used. Artifacts and
large result bundles are not committed; recreate them from locked sources.
The build script refuses to replace an existing XCFramework directory.

`Scripts/process_restart.py SIMULATOR_UUID HOST_APP_PATH EVIDENCE_JSON`
installs/launches only the dedicated host, injects each boundary, sends SIGKILL
to the PID returned by simctl, restarts, and verifies continuation. Use a
disposable simulator. It must never target the normal OneWay app.

## Evidence limits

- The store uses encrypted SQLite rows, WAL/FULL, Keychain roots, a protected
  hash manifest and Keychain commit anchors. Its full-manifest rewrite has
  growing cost; the 10,000-message test measures that real cost.
- The two-resource Keychain/SQLite pending-anchor reconciliation has a narrow
  ambiguity after interrupted commits. Completed-snapshot rollback is tested;
  arbitrary attacker rollback during an interrupted transition is not solved.
- One in-process engine owns each device store. Concurrent independent store
  instances/extensions are not a supported production design; stale instances
  fail integrity checks and must be discarded, not force-restored.
- Data Protection attributes are applied; hardware enforcement requires a
  physical-device test, explicitly skipped on the simulator.
- No disk-full/fsync fault campaign, plaintext-memory/crash-dump proof,
  independent audit, directory transparency, or production CBOR envelope is
  claimed. Candidate-state copies/FFI buffers still need a zeroization review.
- Test public-key pinning detects changes after an explicit local trust input.
  It does not solve unauthenticated first contact or signed account enrollment.
- Recovery tests use the unchanged Phase1B2 implementation; local restart
  restores current state, while backup recovery must create fresh identity.
- No runtime mode negotiation, plaintext fallback, custom ratchet, or custom PQ
  algorithm exists. Experimental full-tag mode stays experimental.
- UniFFI introduces MPL-2.0 components. This stack is not Apache-only.

The complete gate assessment is in
`docs/security/alternative-crypto/PHASE_ALT_2_VODOZEMAC_IOS_ADMISSION_REPORT.md`.
