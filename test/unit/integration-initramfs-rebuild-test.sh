#!/bin/bash

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cp "$root/test/integration.d/initramfs-rebuild-test.sh" "$tmp/scenario.sh"
export REBUILD_TEST_ROOT="$root"
cat >"$tmp/base-test.sh" <<'EOF'
set -euo pipefail
ROOT="$REBUILD_TEST_ROOT"
RUN_DIR="$REBUILD_TEST_RUN"
mkdir -p "$RUN_DIR"
BOOT_TIMEOUT=0
SCENARIO=initramfs-rebuild
FAILURES=0
source <(sed -n '/^check() {/,/^}/p; /^finish() {/,/^}/p' "$ROOT/test/integration.d/base-test.sh")
log() { echo "$1"; }
base_image_ready() { return 0; }
start_vm_from_base() { touch "$RUN_DIR/overlay"; }
wait_for_ssh() { return 0; }
vm_running() { return 0; }
capture_console() { touch "$RUN_DIR/$1.png"; }
ocr_screen() { echo 'Limine hash mismatch'; }
stop_vm() { touch "$RUN_DIR/stopped"; }
ssh_guest() {
  case "$1" in
    mktemp*) echo /tmp/monarch-limine-boot.test.py ;;
    'cat > '*) cat >"$RUN_DIR/checker" ;;
    'rm -f '*) return 0 ;;
    *boot_id*)
      if [[ -f $RUN_DIR/rebooted && $REBUILD_TEST_MODE != no-reboot ]]; then
        echo 22222222-2222-2222-2222-222222222222
      else
        echo 11111111-1111-1111-1111-111111111111
      fi ;;
    *firmware*) [[ $REBUILD_TEST_MODE != no-efi ]] ;;
    *is-system-running*) [[ $REBUILD_TEST_MODE != degraded ]] ;;
    *) return 1 ;;
  esac
}
ssh_sudo() {
  case "$1" in
    python3*)
      [[ -s $RUN_DIR/checker ]] || return 1
      [[ $REBUILD_TEST_MODE != bad-hash ]] || return 1
      if [[ $REBUILD_TEST_MODE == changed-menu && -f $RUN_DIR/rebuilt ]]; then
        echo '{"entries":["duplicate"],"selected":1,"foreign":[],"files":{"uki":"hash"}}'
      else
        echo '{"entries":[],"selected":1,"foreign":[],"files":{"uki":"hash"}}'
      fi ;;
    *limine-mkinitcpio*)
      echo 'rebuilding initramfs'
      [[ $REBUILD_TEST_MODE != rebuild-failed ]] || return 1
      touch "$RUN_DIR/rebuilt" ;;
    'systemctl reboot')
      rm -f "$RUN_DIR/checker"
      touch "$RUN_DIR/rebooted" ;;
    'cat /boot/limine.conf') echo 'menu' ;;
    *journalctl*) echo 'journal' ;;
    *) return 1 ;;
  esac
}
EOF

REBUILD_TEST_MODE=healthy REBUILD_TEST_RUN="$tmp/healthy" bash "$tmp/scenario.sh" >"$tmp/healthy.log"
[[ -f $tmp/healthy/overlay && -f $tmp/healthy/stopped && -s $tmp/healthy/rebuild.log ]]
[[ -f $tmp/healthy/success-initramfs-rebuild-boot.png && -s $tmp/healthy/boot-ids.txt ]]
echo 'ok - a rebuild and a new UEFI boot pass on the throwaway overlay'

for mode in no-efi bad-hash changed-menu rebuild-failed no-reboot degraded; do
  if REBUILD_TEST_MODE="$mode" REBUILD_TEST_RUN="$tmp/$mode" bash "$tmp/scenario.sh" >"$tmp/$mode.log" 2>&1; then
    echo "not ok - $mode was accepted"
    exit 1
  fi
  echo "ok - $mode fails the rebuild scenario"
done
[[ -f $tmp/no-reboot/failure-rebuild-reboot.png && -s $tmp/no-reboot/console.log ]]
[[ -f $tmp/rebuild-failed/failure-initramfs-rebuild.png ]]
