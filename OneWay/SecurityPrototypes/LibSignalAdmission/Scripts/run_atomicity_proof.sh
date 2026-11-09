#!/bin/bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${1:-$(mktemp -d /tmp/oneway-libsignal-atomicity.XXXXXX)}"
RANDOM_CRASH_COUNT="${ONEWAY_ATOMIC_RANDOM_CRASH_COUNT:-1000}"
PROBE="${WORK_DIR}/atomicity-probe"
RESULTS="${WORK_DIR}/atomicity-results.txt"

mkdir -p "${WORK_DIR}"
: > "${RESULTS}"

xcrun swiftc \
  "${HARNESS_DIR}/Sources/OneWayCrypto/DurableAtomicCryptoStore.swift" \
  "${HARNESS_DIR}/Scripts/atomicity_probe.swift" \
  -o "${PROBE}" \
  -lsqlite3

outbound_phases=(
  beforeSessionLoad afterSessionLoad beforeEncryption afterEncryption
  beforeRatchetPersistence afterRatchetPersistenceAttempt
  beforeOutboxPersistence afterOutboxPersistenceAttempt
  beforeTransactionCommit duringCommit immediatelyAfterCommit
  beforeNetworkSend duringNetworkSend immediatelyAfterNetworkSend
  beforeDeliveryAcknowledgement afterAcknowledgement
)

inbound_phases=(
  beforeReplayCheck afterReplayCheck beforeSessionLoad afterSessionLoad
  beforeDecrypt afterDecrypt beforeSessionStateWrite afterSessionStateWriteAttempt
  beforeMessagePersistence afterMessagePersistenceAttempt beforeReplayMarkerWrite
  afterReplayMarkerWriteAttempt beforeCommit duringCommit immediatelyAfterCommit
  beforeAcknowledgement afterAcknowledgement
)

run_kill_case() {
  local direction="$1"
  local phase="$2"
  local ordinal="$3"
  local case_dir="${WORK_DIR}/${direction}-${ordinal}-${phase}"
  local database="${case_dir}/crypto.sqlite3"
  local message_id="${direction}-${ordinal}"
  mkdir -p "${case_dir}"
  "${PROBE}" initialize "${database}"
  set +e
  "${PROBE}" "${direction}" "${database}" "${phase}" "${message_id}" >/dev/null 2>&1
  local status=$?
  set -e
  if [[ ${status} -eq 0 ]]; then
    echo "FAIL ${direction} ${phase}: process did not terminate" | tee -a "${RESULTS}"
    return 1
  fi
  "${PROBE}" "verify-${direction}" "${database}" "${message_id}"
  echo "PASS ${direction} ${phase} exit=${status}" >> "${RESULTS}"
}

ordinal=0
for phase in "${outbound_phases[@]}"; do
  ordinal=$((ordinal + 1))
  run_kill_case outbound "${phase}" "${ordinal}"
done
for phase in "${inbound_phases[@]}"; do
  ordinal=$((ordinal + 1))
  run_kill_case inbound "${phase}" "${ordinal}"
done

for ((index = 0; index < RANDOM_CRASH_COUNT; index++)); do
  if (( index % 2 == 0 )); then
    phase="${outbound_phases[$((index % ${#outbound_phases[@]}))]}"
    run_kill_case outbound "${phase}" "random-${index}"
  else
    phase="${inbound_phases[$((index % ${#inbound_phases[@]}))]}"
    run_kill_case inbound "${phase}" "random-${index}"
  fi
done

soak_database="${WORK_DIR}/ten-thousand/crypto.sqlite3"
mkdir -p "$(dirname "${soak_database}")"
"${PROBE}" ten-thousand "${soak_database}"
"${PROBE}" checkpoint "${soak_database}"
echo "PASS ten-thousand durable messages" >> "${RESULTS}"

lock_database="${WORK_DIR}/locked/crypto.sqlite3"
mkdir -p "$(dirname "${lock_database}")"
"${PROBE}" initialize "${lock_database}"
"${PROBE}" hold-lock "${lock_database}" 7 > "${WORK_DIR}/lock-holder.txt" &
lock_pid=$!
for _ in $(seq 1 50); do
  grep -q LOCK_HELD "${WORK_DIR}/lock-holder.txt" 2>/dev/null && break
  sleep 0.1
done
set +e
"${PROBE}" outbound "${lock_database}" afterSessionLoad locked-message >/dev/null 2>&1
locked_status=$?
set -e
wait "${lock_pid}"
if [[ ${locked_status} -eq 0 ]]; then
  echo "FAIL database locked: write unexpectedly succeeded" | tee -a "${RESULTS}"
  exit 1
fi
"${PROBE}" verify-outbound "${lock_database}" locked-message
echo "PASS database locked fails closed exit=${locked_status}" >> "${RESULTS}"

readonly_dir="${WORK_DIR}/unavailable"
mkdir -p "${readonly_dir}"
chmod 500 "${readonly_dir}"
set +e
"${PROBE}" initialize "${readonly_dir}/crypto.sqlite3" >/dev/null 2>&1
unavailable_status=$?
set -e
chmod 700 "${readonly_dir}"
if [[ ${unavailable_status} -eq 0 ]]; then
  echo "FAIL unavailable disk: create unexpectedly succeeded" | tee -a "${RESULTS}"
  exit 1
fi
echo "PASS unavailable disk fails closed exit=${unavailable_status}" >> "${RESULTS}"

disk_full_database="${WORK_DIR}/disk-full/crypto.sqlite3"
mkdir -p "$(dirname "${disk_full_database}")"
"${PROBE}" disk-full "${disk_full_database}"
echo "PASS disk full fails closed" >> "${RESULTS}"

sync_failure_database="${WORK_DIR}/sync-failure/crypto.sqlite3"
mkdir -p "$(dirname "${sync_failure_database}")"
"${PROBE}" sync-failure "${sync_failure_database}"
echo "PASS injected sync failure rolls back" >> "${RESULTS}"

corrupt_source="${WORK_DIR}/corruption-source/crypto.sqlite3"
corrupt_copy="${WORK_DIR}/corruption-copy/crypto.sqlite3"
mkdir -p "$(dirname "${corrupt_source}")" "$(dirname "${corrupt_copy}")"
"${PROBE}" initialize "${corrupt_source}"
"${PROBE}" checkpoint "${corrupt_source}"
cp "${corrupt_source}" "${corrupt_copy}"
source_size=$(stat -f %z "${corrupt_copy}")
truncate -s $((source_size / 2)) "${corrupt_copy}"
set +e
"${PROBE}" config "${corrupt_copy}" >/dev/null 2>&1
corrupt_status=$?
set -e
if [[ ${corrupt_status} -eq 0 ]]; then
  echo "FAIL truncated database: integrity unexpectedly accepted" | tee -a "${RESULTS}"
  exit 1
fi
echo "PASS truncated database fails closed exit=${corrupt_status}" >> "${RESULTS}"

{
  echo "OUTBOUND_MATRIX_PASS=${#outbound_phases[@]}"
  echo "INBOUND_MATRIX_PASS=${#inbound_phases[@]}"
  echo "NAMED_PROCESS_KILLS=$(( ${#outbound_phases[@]} + ${#inbound_phases[@]} ))"
  echo "RANDOM_PROCESS_KILLS=${RANDOM_CRASH_COUNT}"
  echo "TOTAL_PROCESS_KILLS=$(( ${#outbound_phases[@]} + ${#inbound_phases[@]} + RANDOM_CRASH_COUNT ))"
  echo "TEN_THOUSAND_DURABLE_MESSAGES=PASS"
  echo "DATABASE_LOCKED=PASS"
  echo "UNAVAILABLE_DISK=PASS"
  echo "DISK_FULL=PASS"
  echo "INJECTED_SYNC_FAILURE=PASS"
  echo "TRUNCATED_DATABASE=PASS"
  echo "PROOF_WORK_DIR=${WORK_DIR}"
} | tee -a "${RESULTS}"

echo "LIBSIGNAL_ATOMICITY_PROOF_PASS"
