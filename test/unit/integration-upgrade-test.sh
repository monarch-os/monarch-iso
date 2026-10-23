#!/bin/bash

set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$root/test/integration.d/upgrade-test.sh" "$tmp/scenario.sh"
export UPGRADE_TEST_ROOT="$root" MONARCH_INTEGRATION_RENDER_NODE=/dev/null
cat >"$tmp/base-test.sh" <<'EOF'
set -euo pipefail
ROOT="$UPGRADE_TEST_ROOT"
RUN_DIR="$UPGRADE_TEST_RUN"
mkdir -p "$RUN_DIR"
BOOT_TIMEOUT=0
GUEST_USER=monarch
SCENARIO=upgrade
FAILURES=0
source <(sed -n '/^check() {/,/^}/p; /^finish() {/,/^}/p' "$ROOT/test/integration.d/base-test.sh")
log() { echo "$1"; }
base_image_ready() { return 0; }
start_vm_from_base() { touch "$RUN_DIR/overlay"; }
wait_for_ssh() { return 0; }
vm_running() { return 0; }
capture_console() { touch "$RUN_DIR/$1.png"; }
ocr_screen() { echo 'boot failed'; }
stop_vm() { touch "$RUN_DIR/stopped"; }
ssh_guest() {
  printf '%s\n' "$1" >>"$RUN_DIR/guest-calls"
  case "$1" in
    'mktemp -d /tmp/monarch-upgrade-shot.'*) echo /tmp/monarch-upgrade-shot.fixture ;;
    *'niri msg action screenshot-screen'*) return 0 ;;
    'cat /tmp/monarch-upgrade-shot.'*) echo png ;;
    'rm -rf /tmp/monarch-upgrade-shot.'*) return 0 ;;
    'mkdir -p ~/.local/state/monarch;'*) touch "$RUN_DIR/reboot-required" ;;
    'test -f ~/.local/state/monarch/reboot-required') [[ -f $RUN_DIR/reboot-required ]] ;;
    *boot_id*)
      if [[ -f $RUN_DIR/rebooted && $UPGRADE_TEST_MODE != reboot-failed || -f $RUN_DIR/updated && $UPGRADE_TEST_MODE == auto-reboot ]]; then
        echo 22222222-2222-2222-2222-222222222222
      else
        echo 11111111-1111-1111-1111-111111111111
      fi ;;
    'pacman -Q')
      if [[ -f $RUN_DIR/updated && $UPGRADE_TEST_MODE != no-changes ]]; then echo 'monarch 2'; else echo 'monarch 1'; fi ;;
    *'120s bash -c'*)
      if [[ -f $RUN_DIR/rebooted ]]; then
        [[ $UPGRADE_TEST_MODE != desktop-after-failed ]]
      else
        [[ $UPGRADE_TEST_MODE != desktop-before-failed ]]
      fi ;;
    *'env -u MONARCH_UPDATE_LOGGED MONARCH_PATH=/usr/share/monarch monarch-update -y </dev/null')
      touch "$RUN_DIR/updated"
      [[ $UPGRADE_TEST_MODE != lost-reboot-marker ]] || rm "$RUN_DIR/reboot-required"
      case $UPGRADE_TEST_MODE in
        update-failed) return 42 ;;
        update-timeout) return 124 ;;
      esac ;;
    *firmware*) [[ $UPGRADE_TEST_MODE != no-efi ]] ;;
    *is-system-running*) [[ $UPGRADE_TEST_MODE != degraded ]] ;;
    'systemctl --failed'*)
      case $UPGRADE_TEST_MODE in
        failed-unit) echo 'broken.service loaded failed failed' ;;
        failed-query) return 255 ;;
      esac ;;
    *) echo "unexpected SSH command: $1" >&2; return 99 ;;
  esac
}
ssh_sudo() {
  printf '%s\n' "$1" >>"$RUN_DIR/root-calls"
  case "$1" in
    'mkdir -p /etc/sddm.conf.d'*) touch "$RUN_DIR/test-authorization" ;;
    'rm -f /etc/sudoers.d/99-monarch-upgrade-test') rm "$RUN_DIR/test-authorization" ;;
    'systemctl reboot') touch "$RUN_DIR/rebooted" ;;
    *journalctl*) echo journal ;;
    *) return 99 ;;
  esac
}
EOF

UPGRADE_TEST_MODE=healthy UPGRADE_TEST_RUN="$tmp/healthy" bash "$tmp/scenario.sh" >"$tmp/healthy.log"
[[ -f $tmp/healthy/overlay && -f $tmp/healthy/stopped && -s $tmp/healthy/packages.diff ]]
[[ ! -f $tmp/healthy/test-authorization && -f $tmp/healthy/success-upgrade-after.png ]]
grep -qF 'env -u MONARCH_UPDATE_LOGGED MONARCH_PATH=/usr/share/monarch monarch-update -y </dev/null' "$tmp/healthy/guest-calls"
[[ $(wc -l <"$tmp/healthy/boot-ids.txt") == 2 ]]
echo 'ok - a real updater invocation, package change, controlled reboot and desktop check are required'

for mode in update-failed update-timeout no-changes auto-reboot lost-reboot-marker reboot-failed desktop-before-failed desktop-after-failed no-efi degraded failed-unit failed-query; do
  if UPGRADE_TEST_MODE="$mode" UPGRADE_TEST_RUN="$tmp/$mode" bash "$tmp/scenario.sh" >"$tmp/$mode.log" 2>&1; then
    echo "FAIL: $mode passed the upgrade scenario" >&2
    exit 1
  fi
  echo "ok - $mode cannot pass as a successful upgrade"
done
[[ ! -f $tmp/desktop-before-failed/updated ]]
[[ ! -f $tmp/auto-reboot/rebooted ]]
[[ -f $tmp/update-timeout/failure-upgrade-update.png && -f $tmp/update-timeout/update-status.txt ]]
[[ $(cat "$tmp/update-timeout/update-status.txt") == 124 ]]
if MONARCH_INTEGRATION_OFFLINE=true UPGRADE_TEST_MODE=healthy UPGRADE_TEST_RUN="$tmp/offline" bash "$tmp/scenario.sh" >"$tmp/offline.log" 2>&1; then
  echo 'FAIL: an offline run pretended to test upgrades' >&2
  exit 1
fi
[[ ! -f $tmp/offline/overlay ]]
echo 'ok - network-required upgrades are refused before starting an offline VM'

for deadline in 0 -1 bad '30; false'; do
  if MONARCH_INTEGRATION_UPDATE_TIMEOUT="$deadline" UPGRADE_TEST_MODE=healthy UPGRADE_TEST_RUN="$tmp/invalid-timeout" bash "$tmp/scenario.sh" >"$tmp/timeout.log" 2>&1; then
    echo 'FAIL: an invalid update deadline was accepted' >&2
    exit 1
  fi
  [[ ! -f $tmp/invalid-timeout/overlay ]]
done
echo 'ok - invalid update deadlines are rejected before starting a VM'
