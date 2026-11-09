#!/usr/bin/env bash
set -euo pipefail

# LiveKit's prebuilt RustLiveKitUniFFI and LiveKitWebRTC XCFrameworks do not
# currently ship dSYMs. App Store Connect accepts the app, but reports missing
# symbol uploads for the embedded framework UUIDs. During an iOS archive,
# generate valid matching dSYM bundles from the Mach-O symbol data that remains
# in each binary and place them beside the app dSYM in the archive.

if [[ "${ACTION:-}" != "install" || "${PLATFORM_NAME:-}" != "iphoneos" ]]; then
  exit 0
fi

if [[ -z "${DWARF_DSYM_FOLDER_PATH:-}" ]]; then
  echo "error: DWARF_DSYM_FOLDER_PATH is unavailable."
  exit 1
fi

mkdir -p "${DWARF_DSYM_FOLDER_PATH}"

generate_dsym() {
  local framework_name="$1"
  local binary="${BUILT_PRODUCTS_DIR}/${framework_name}.framework/${framework_name}"
  local output="${DWARF_DSYM_FOLDER_PATH}/${framework_name}.framework.dSYM"
  local dwarf="${output}/Contents/Resources/DWARF/${framework_name}"

  if [[ ! -f "${binary}" ]]; then
    echo "error: Cannot locate ${framework_name} at ${binary}"
    exit 1
  fi

  xcrun dsymutil "${binary}" -o "${output}"

  if [[ ! -f "${dwarf}" ]]; then
    echo "error: dsymutil did not create a DWARF file for ${framework_name}."
    exit 1
  fi

  local binary_uuids
  local dsym_uuids
  binary_uuids="$(xcrun dwarfdump --uuid "${binary}" | awk '{print toupper($2)}' | sort)"
  dsym_uuids="$(xcrun dwarfdump --uuid "${dwarf}" | awk '{print toupper($2)}' | sort)"

  if [[ -z "${binary_uuids}" || "${binary_uuids}" != "${dsym_uuids}" ]]; then
    echo "error: dSYM UUID mismatch for ${framework_name}."
    echo "Binary UUIDs: ${binary_uuids:-none}"
    echo "dSYM UUIDs: ${dsym_uuids:-none}"
    exit 1
  fi

  echo "Generated ${framework_name}.framework.dSYM (${dsym_uuids//$'\n'/, })"
}

generate_dsym "RustLiveKitUniFFI"
generate_dsym "LiveKitWebRTC"
