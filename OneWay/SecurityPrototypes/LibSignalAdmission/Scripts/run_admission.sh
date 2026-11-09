#!/usr/bin/env bash
set -euo pipefail

VERSION="v0.106.0"
COMMIT="fc90b90fa2b9c37822fa47ba0e0dcdf387a0c071"
TREE="fc929e7149f8a8372d63cda35d28e7b566e9c687"
ARCHIVE="libsignal-client-ios-build-v0.106.0.tar.gz"
ARCHIVE_SHA256="ddfa5ac6fd6e0da9ebe4eb23890af048140aec1a3e916d3eccadc1036627152f"
UPSTREAM="https://github.com/signalapp/libsignal.git"
ARTIFACT_URL="https://build-artifacts.signal.org/libraries/${ARCHIVE}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORK_DIR="${1:-$(mktemp -d /tmp/oneway-libsignal-admission.XXXXXX)}"

if [[ -e "${WORK_DIR}" && -n "$(ls -A "${WORK_DIR}" 2>/dev/null || true)" ]]; then
  echo "error: work directory must be empty: ${WORK_DIR}" >&2
  exit 64
fi
mkdir -p "${WORK_DIR}"

git clone --filter=blob:none --branch "${VERSION}" --depth 1 "${UPSTREAM}" "${WORK_DIR}/source"
cd "${WORK_DIR}/source"
[[ "$(git rev-parse HEAD)" == "${COMMIT}" ]] || { echo "LIBSIGNAL PIN MISMATCH — REVIEW REQUIRED" >&2; exit 2; }
[[ "$(git rev-parse "${VERSION}^{}")" == "${COMMIT}" ]] || { echo "LIBSIGNAL PIN MISMATCH — REVIEW REQUIRED" >&2; exit 2; }
[[ "$(git rev-parse 'HEAD^{tree}')" == "${TREE}" ]] || { echo "LIBSIGNAL PIN MISMATCH — REVIEW REQUIRED" >&2; exit 2; }

curl --fail --location --proto '=https' --tlsv1.2 "${ARTIFACT_URL}" --output "${WORK_DIR}/${ARCHIVE}"
python3 "${HARNESS_DIR}/Scripts/verify_libsignal_artifact.py" \
  "${HARNESS_DIR}/Artifacts/libsignal-ios-v0.106.0.json" "${WORK_DIR}/${ARCHIVE}"

mkdir -p "${WORK_DIR}/admitted"
tar -xzf "${WORK_DIR}/${ARCHIVE}" -C "${WORK_DIR}/admitted"

if [[ "${RUN_SOURCE_BUILD:-1}" == "1" ]]; then
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
  for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
    CARGO_BUILD_TARGET="${target}" CARGO_TARGET_DIR="${WORK_DIR}/source-build" \
      "${WORK_DIR}/source/swift/build_ffi.sh" --release
    shasum -a 256 "${WORK_DIR}/source-build/${target}/release/libsignal_ffi.a"
  done
fi

if [[ "${RUN_IOS_PROOF:-1}" == "1" ]]; then
  command -v xcodegen >/dev/null
  command -v pod >/dev/null
  simulator_id="${SIMULATOR_ID:-$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next(x["udid"] for xs in d.values() for x in xs if x.get("isAvailable") and x["name"].startswith("iPhone")))')}"
  mkdir -p "${WORK_DIR}/integration" "${WORK_DIR}/vendor/LibSignalClient"
  rsync -a "${HARNESS_DIR}/Sources" "${HARNESS_DIR}/Tests" "${WORK_DIR}/integration/"
  cp "${HARNESS_DIR}/project.yml" "${HARNESS_DIR}/Podfile" "${WORK_DIR}/integration/"
  rsync -a "${WORK_DIR}/source/swift" "${WORK_DIR}/vendor/LibSignalClient/"
  rsync -a "${WORK_DIR}/source/bin" "${WORK_DIR}/vendor/LibSignalClient/"
  cp "${WORK_DIR}/source/LibSignalClient.podspec" "${WORK_DIR}/vendor/LibSignalClient/"
  cd "${WORK_DIR}/integration"
  xcodegen generate
  LIBSIGNAL_ADMISSION_VENDOR="${WORK_DIR}/vendor/LibSignalClient" \
    LIBSIGNAL_FFI_PREBUILD_CHECKSUM="${ARCHIVE_SHA256}" pod install
  common=(
    -workspace OneWayLibSignalAdmission.xcworkspace
    -scheme OneWayCryptoAdmission
    LIBSIGNAL_ADMISSION_SIGNAL_FFI_MODULE="${WORK_DIR}/vendor/LibSignalClient/swift/Sources/SignalFfi"
    LIBSIGNAL_FFI_PREBUILD_CHECKSUM="${ARCHIVE_SHA256}"
  )
  xcodebuild test "${common[@]}" -configuration Debug \
    -destination "platform=iOS Simulator,id=${simulator_id}" \
    -derivedDataPath "${WORK_DIR}/DerivedData-Debug" \
    LIBSIGNAL_ADMISSION_FFI_ARCHIVE="${WORK_DIR}/admitted/target/aarch64-apple-ios-sim/release/libsignal_ffi.a"
  xcodebuild build "${common[@]}" -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "${WORK_DIR}/DerivedData-Release" \
    CODE_SIGNING_ALLOWED=NO \
    LIBSIGNAL_ADMISSION_FFI_ARCHIVE="${WORK_DIR}/admitted/target/aarch64-apple-ios/release/libsignal_ffi.a"
fi

echo "libsignal admission evidence completed in ${WORK_DIR}"
