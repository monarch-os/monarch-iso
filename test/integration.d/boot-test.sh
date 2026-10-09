#!/bin/bash

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }

log "Booting the installed system"
boot_started=$(date +%s%N)
start_vm_from_base
if ! wait_for_ssh "$BOOT_TIMEOUT" failure-boot-ssh-timeout; then
  echo "--- last lines of the serial console ---" >&2
  tail -n 40 "$RUN_DIR/serial.log" >&2 2>/dev/null || true
  exit 1
fi
boot_ms=$((($(date +%s%N) - boot_started) / 1000000))
log "SSH answered within ${boot_ms} ms of power-on"

# Keep degraded startup and failed SSH queries visible in the assertions.
state=$(ssh_guest "timeout 120 systemctl is-system-running --wait" 2>/dev/null | tr -d '\r' || true)
ssh_guest "systemd-analyze" >"$RUN_DIR/systemd-analyze.txt" 2>/dev/null || true
ssh_guest "systemd-analyze blame --no-pager | head -n 20" >"$RUN_DIR/systemd-analyze-blame.txt" 2>/dev/null || true
ssh_guest "systemctl --failed --no-legend --plain" >"$RUN_DIR/failed-units.txt" 2>/dev/null ||
  echo "could not query failed units over SSH" >"$RUN_DIR/failed-units.txt"
printf '{"boot_to_ssh_ms": %d, "system_state": "%s"}\n' "$boot_ms" "$state" >"$RUN_DIR/boot-timing.json"

check "systemd reports the system running (got: ${state:-nothing})" test "$state" = running
check "no failed units" test ! -s "$RUN_DIR/failed-units.txt"
capture_console "success-boot"

stop_vm
finish
