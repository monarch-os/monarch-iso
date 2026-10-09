#!/bin/bash

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cp "$root/test/integration.d/boot-test.sh" "$tmp/boot-test.sh"
export BOOT_TEST_ROOT="$root" MONARCH_INTEGRATION_ISO="$tmp/boot-candidate.iso"

cat >"$tmp/base-test.sh" <<'EOF'
source "$BOOT_TEST_ROOT/test/integration.d/base-test.sh"
trap - EXIT
rmdir "$RUN_DIR" "$BASE_DIR/runs" "$BASE_DIR" 2>/dev/null || true
RUN_DIR="$BOOT_TEST_RUN"
BOOT_TIMEOUT=45
mkdir -p "$RUN_DIR"
base_image_ready() { return 0; }
start_vm_from_base() { echo 'kernel boot failure' >"$RUN_DIR/serial.log"; }
wait_for_ssh() {
  (( $1 == 45 )) && [[ $2 == "failure-boot-ssh-timeout" ]]
  [[ ${BOOT_TEST_MODE:-running} != "timeout" ]]
}
stop_vm() { touch "$RUN_DIR/stopped"; }
capture_console() { touch "$RUN_DIR/$1.png"; }
ssh_guest() {
  case "$1" in
    *is-system-running*)
      echo "${BOOT_TEST_STATE:-running}"
      [[ ${BOOT_TEST_STATE:-running} == "running" ]]
      ;;
    'systemd-analyze') echo 'Startup finished in 10s' ;;
    *'systemd-analyze blame'*) echo '1s sddm.service' ;;
    *'systemctl --failed'*)
      case "${BOOT_TEST_MODE:-running}" in
        query-failed) return 255 ;;
        failed-unit) echo 'broken.service loaded failed failed' ;;
      esac
      ;;
    *) return 1 ;;
  esac
}
EOF

BOOT_TEST_RUN="$tmp/running" bash "$tmp/boot-test.sh" >"$tmp/running.log"
python3 - "$tmp/running/boot-timing.json" <<'PY'
import json
import sys
timing = json.load(open(sys.argv[1]))
assert timing['system_state'] == 'running', timing
assert timing['boot_to_ssh_ms'] >= 0, timing
PY
[[ -s $tmp/running/systemd-analyze.txt && -s $tmp/running/systemd-analyze-blame.txt ]]
[[ -f $tmp/running/stopped && -f $tmp/running/success-boot.png ]]
echo 'ok - a healthy cold boot records timings and passes'

if BOOT_TEST_RUN="$tmp/degraded" BOOT_TEST_STATE=degraded bash "$tmp/boot-test.sh" >"$tmp/degraded.log"; then
  echo 'not ok - degraded startup was accepted'
  exit 1
fi
grep -qF 'not ok - systemd reports the system running (got: degraded)' "$tmp/degraded.log"
[[ -s $tmp/degraded/boot-timing.json && -f $tmp/degraded/stopped ]]
echo 'ok - degraded startup fails while retaining diagnostics'

for mode in failed-unit query-failed; do
  if BOOT_TEST_RUN="$tmp/$mode" BOOT_TEST_MODE="$mode" bash "$tmp/boot-test.sh" >"$tmp/$mode.log"; then
    echo "not ok - $mode was accepted"
    exit 1
  fi
  grep -qF 'not ok - no failed units' "$tmp/$mode.log"
  [[ -s $tmp/$mode/failed-units.txt ]]
  echo "ok - $mode cannot pass as a healthy system"
done

if BOOT_TEST_RUN="$tmp/timeout" BOOT_TEST_MODE=timeout bash "$tmp/boot-test.sh" >"$tmp/timeout.log" 2>&1; then
  echo 'not ok - unreachable guest was accepted'
  exit 1
fi
grep -qF 'kernel boot failure' "$tmp/timeout.log"
echo 'ok - an unreachable guest fails with serial diagnostics'
