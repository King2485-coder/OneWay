#!/bin/bash
set -euo pipefail
# Run from repository root. Use canonical (non-symlink) CARGO_HOME on macOS.
base="$(pwd)/SecurityPrototypes/VodozemacAdmission"
work="${ALT2_BUILD_ROOT:?Set ALT2_BUILD_ROOT to a disposable absolute build directory}"
mkdir -p "$work"
cargo +1.89.0 metadata --locked --format-version 1 --manifest-path "$base/Cargo.toml" > "$work/metadata.json"
python3 - "$work/metadata.json" <<'PY'
import json,sys
p=next(p for p in json.load(open(sys.argv[1]))['packages'] if p['name']=='vodozemac')
assert p['version']=='0.11.1'
assert p['source'].endswith('#3e11ae87d157da6bcac3cbf7825d37c8f5ed60af')
PY
CARGO_TARGET_DIR="$work/bindgen" cargo +1.89.0 build --locked --manifest-path "$base/Cargo.toml" --features bindgen
(cd "$base"; "$work/bindgen/debug/bindgen" generate --library "$work/bindgen/debug/liboneway_vodozemac.dylib" --language swift --out-dir Generated)
cp "$base/Generated/oneway_vodozemacFFI.modulemap" "$base/Generated/module.modulemap"
rustup target add --toolchain 1.89.0 aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
for mode in stable full; do
  feature=""; [[ "$mode" != full ]] || feature="full-tag"
  for arch in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
    CARGO_TARGET_DIR="$work/$mode" cargo +1.89.0 build --locked --release --lib --manifest-path "$base/Cargo.toml" --features "$feature" --target "$arch"
  done
  out="$base/Artifacts/$mode"
  mkdir -p "$out/iphoneos" "$out/iphonesimulator"
  cp "$work/$mode/aarch64-apple-ios/release/liboneway_vodozemac.a" "$out/iphoneos/"
  lipo -create "$work/$mode/aarch64-apple-ios-sim/release/liboneway_vodozemac.a" "$work/$mode/x86_64-apple-ios/release/liboneway_vodozemac.a" -output "$out/iphonesimulator/liboneway_vodozemac.a"
  # Keep an existing artifact intact; select a fresh output for a comparison build.
  xcodebuild -create-xcframework -library "$out/iphoneos/liboneway_vodozemac.a" -headers "$base/Generated" -library "$out/iphonesimulator/liboneway_vodozemac.a" -headers "$base/Generated" -output "$out/OneWayVodozemac.xcframework"
done
