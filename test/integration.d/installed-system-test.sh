#!/bin/bash

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }

start_vm_from_base
wait_for_ssh "$BOOT_TIMEOUT"
capture_console "success-installed-system-boot"

ssh_sudo 'journalctl -b --no-pager' >"$RUN_DIR/journal.log"
ssh_sudo 'cat /var/log/monarch-install.log' >"$RUN_DIR/install.log"
ssh_guest 'pacman -Q' >"$RUN_DIR/packages.txt"

check "Root filesystem is installed on btrfs" ssh_guest 'test "$(findmnt -n -o FSTYPE /)" = btrfs'
check "Installed hostname matches the test machine" ssh_guest "test \"\$(hostname)\" = '$GUEST_HOSTNAME'"
check "Runtime, settings and desktop packages are installed" ssh_guest 'pacman -Q monarch monarch-settings linux-cachyos niri noctalia sddm'
check "Monarch command routes are valid" ssh_guest 'monarch commands --check'
check "SDDM starts successfully" ssh_guest 'timeout 120 bash -c "until systemctl is-active --quiet sddm; do sleep 2; done"'
check "EFI boot files exist" ssh_sudo 'test -s /boot/EFI/BOOT/BOOTX64.EFI && test -s /boot/limine.conf'

finish
