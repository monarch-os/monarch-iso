#!/bin/bash
# integration:opt-in

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }
start_vm_from_base
wait_for_ssh "$BOOT_TIMEOUT"
check "Snapshot test starts with the reused UKI" \
  ssh_sudo 'grep -qx "Prebuilt UKI reused" /var/log/monarch-install.log'
((FAILURES == 0)) || { finish; exit 1; }
boot_id=$(ssh_guest 'cat /proc/sys/kernel/random/boot_id')
ssh_sudo 'set -euo pipefail
  mkdir -p /run/f1-top
  mount -o subvolid=5 "$(findmnt -no SOURCE / | sed "s/\[.*//")" /run/f1-top
  mkdir /run/f1-top/@f1
  btrfs subvolume snapshot -r / /run/f1-top/@f1/snapshot
  umount /run/f1-top
  cp /boot/limine.conf /boot/limine.conf.before-snapshot
  sed -i "s|rootflags=subvol=@\([ ,]\)|rootflags=subvol=@f1/snapshot\1|g" /boot/limine.conf
  grep -q "rootflags=subvol=@f1/snapshot" /boot/limine.conf
  sha256sum /boot/EFI/Linux/monarch_*.efi' >"$RUN_DIR/uki-before.log"
ssh_sudo 'systemctl reboot' >"$RUN_DIR/reboot.log" 2>&1 || true
started=$SECONDS
while true; do
  current_id=$(MONARCH_INTEGRATION_SSH_DEADLINE=15 ssh_guest 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)
  if [[ $current_id =~ ^[0-9a-f-]{36}$ && $current_id != "$boot_id" ]]; then
    break
  fi
  if ! vm_running || ((SECONDS - started >= BOOT_TIMEOUT)); then
    capture_console failure-f1-snapshot-boot
    echo "The prebuilt UKI did not boot its read-only snapshot" >&2
    exit 1
  fi
  sleep 2
done
check "The read-only snapshot boots with a writable overlay" ssh_sudo 'set -e
  grep -q "rootflags=subvol=@f1/snapshot" /proc/cmdline
  test "$(findmnt -no FSTYPE /)" = overlay
  touch /usr/f1-overlay-writable
  rm /usr/f1-overlay-writable'
ssh_sudo 'journalctl -b --no-pager' >"$RUN_DIR/journal.log"
ssh_sudo 'sha256sum /boot/EFI/Linux/monarch_*.efi' >"$RUN_DIR/uki-after.log"
check "Snapshot boot uses the same UKI" bash -c \
  'diff <(grep " /boot/EFI/Linux/" "$1") "$2"' _ "$RUN_DIR/uki-before.log" "$RUN_DIR/uki-after.log"
finish
