# OneWay ALT-1 — isolated vodozemac evaluation

Not a production adapter, release artifact, or authorization to deploy E2EE.
See `docs/security/PHASE_ALT_1_VODOZEMAC_REPORT.md` for the decision and limitations.

Requires Rust 1.89.0. Run from this directory:

```sh
cargo test --locked
cargo tree --locked
rustup target add --toolchain 1.89.0 aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
cargo build --locked --release -p vodozemac --target aarch64-apple-ios
cargo build --locked --release -p vodozemac --target aarch64-apple-ios-sim
cargo build --locked --release -p vodozemac --target x86_64-apple-ios
```

Cargo pins both version and full Git revision; Cargo.lock pins the transitive graph.
Do not run dependency updates as part of replaying this evidence. The upstream
tag is `0.11.1`, annotated tag object `392d0e380676196137be9182c1c4ca170c19d5e7`,
resolved source commit `3e11ae87d157da6bcac3cbf7825d37c8f5ed60af`.
See `pin.json` for immutable source URL and checksums.

Features: default features disabled; no libolm compatibility, experimental
session config, insecure public-key encryption, low-level API, or WASM feature.
Tests deliberately exercise the stable Olm V1 API, including its 64-bit MAC
limitation. No homegrown cryptographic primitive, ratchet, or MAC extension.

All accounts and messages are generated in memory. Pickle keys are disposable
test material. Candidate snapshots model discarding uncommitted work; they do
not implement SQLite durability, encryption-at-rest policy, Keychain, Swift FFI,
authenticated OneWay routing, enrollment, or revocation. Never send an aborted
candidate ciphertext. Never restore production ratchets from generic backups.

The iOS commands build Rust libraries only. They do not establish a working
Swift wrapper, XCFramework, Xcode archive, or device-executed test result.

Evidence contains official upstream API responses, a dependency graph with
declared licenses, a text dependency tree, and local test/build logs. It is not
a complete distribution SBOM, license clearance, or vulnerability audit.
