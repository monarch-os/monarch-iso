#!/bin/bash

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }

install_checker() {
  guest_checker=$(ssh_guest 'mktemp /tmp/monarch-limine-boot.XXXXXX.py')
  ssh_guest "cat > $(printf %q "$guest_checker")" <"$ROOT/test/lib/limine_boot.py"
}

boot_snapshot() {
  # Run the same checker in the guest and in the VM-free tests. sudo's password
  # pipe owns stdin, so upload the checker before invoking it as root.
  ssh_sudo "python3 $(printf %q "$guest_checker") snapshot /boot/limine.conf /boot" >"$RUN_DIR/$1.json"
}

compare_snapshots() {
  python3 "$ROOT/test/lib/limine_boot.py" compare "$RUN_DIR/$1.json" "$RUN_DIR/$2.json" \
    >"$RUN_DIR/compare-$1-$2.log" 2>&1
}

start_vm_from_base
wait_for_ssh "$BOOT_TIMEOUT"
check "The installed system booted through UEFI" ssh_guest 'test -d /sys/firmware/efi'
((FAILURES == 0)) || { finish; exit 1; }
install_checker
boot_id_pattern='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
boot_id=$(ssh_guest 'cat /proc/sys/kernel/random/boot_id')
[[ $boot_id =~ $boot_id_pattern ]] || { echo "Could not read initial boot ID" >&2; exit 1; }

ssh_sudo 'cat /boot/limine.conf' >"$RUN_DIR/limine.before.conf"
boot_snapshot before
log "Rebuilding the initramfs on the throwaway overlay"
if ! MONARCH_INTEGRATION_SSH_DEADLINE=660 ssh_sudo 'timeout --kill-after=15s 600s limine-mkinitcpio' >"$RUN_DIR/rebuild.log" 2>&1; then
  cat "$RUN_DIR/rebuild.log" >&2
  capture_console "failure-initramfs-rebuild"
  exit 1
fi
ssh_sudo 'cat /boot/limine.conf' >"$RUN_DIR/limine.rebuilt.conf"
boot_snapshot rebuilt
check "Rebuild preserves the default entry and other OS groups" \
  compare_snapshots before rebuilt

# Do not drive the menu or answer hash prompts: only an unattended firmware
# boot of the rebuilt default entry may pass. An old SSH session is not proof
# of a reboot, so wait for a different kernel boot ID, not just an open port.
log "Rebooting through UEFI without console input"
ssh_sudo 'systemctl reboot' >"$RUN_DIR/reboot.log" 2>&1 || true
started=$SECONDS
while true; do
  current_id=$(MONARCH_INTEGRATION_SSH_DEADLINE=15 ssh_guest 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)
  if [[ $current_id =~ $boot_id_pattern && $current_id != "$boot_id" ]]; then
    break
  fi
  if ! vm_running || ((SECONDS - started >= BOOT_TIMEOUT)); then
    capture_console "failure-rebuild-reboot"
    ocr_screen >"$RUN_DIR/console.log"
    echo "The rebuilt system did not reboot unattended into a new boot" >&2
    exit 1
  fi
  sleep 2
done
printf '%s\n' "$boot_id" "$current_id" >"$RUN_DIR/boot-ids.txt"
check "The rebuilt system booted through UEFI" ssh_guest 'test -d /sys/firmware/efi'
check "The rebuilt system reaches running state" ssh_guest 'timeout 120 systemctl is-system-running --wait'
ssh_sudo 'journalctl -b --no-pager' >"$RUN_DIR/journal.log"
ssh_sudo 'cat /boot/limine.conf' >"$RUN_DIR/limine.after.conf"
# /tmp can be a tmpfs: the initial checker does not survive a guest reboot.
install_checker
boot_snapshot after
check "Reboot preserves the rebuilt default entry and other OS groups" \
  compare_snapshots rebuilt after
capture_console "success-initramfs-rebuild-boot"
ssh_guest "rm -f $(printf %q "$guest_checker")"
stop_vm
finish
