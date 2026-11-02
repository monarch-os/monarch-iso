#!/bin/bash
# integration:opt-in

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }
start_vm_from_base
wait_for_ssh "$BOOT_TIMEOUT"
ssh_guest 'cat > /tmp/verify-reused-uki.py' <"$ROOT/test/support/verify-reused-uki.py"
check "Installed UKI differs from the prebuilt image only by its command line" \
  ssh_sudo 'python /tmp/verify-reused-uki.py'
check "Generic US installation reused the build-time UKI" \
  ssh_sudo 'grep -qx "Prebuilt UKI reused" /var/log/monarch-install.log'
check "Reused UKI cold-boots the installed root" ssh_guest \
  'root=$(tr " " "\n" </proc/cmdline | sed -n "s/^root=//p") && device=$(findfs "$root") &&
   actual=$(findmnt -n -o SOURCE /) &&
   test "$(readlink -f "$device")" = "$(readlink -f "${actual%%\[*}")" &&
   grep -Fq "rootflags=subvol=@" /proc/cmdline'
ssh_sudo 'cat /var/log/monarch-install.log' >"$RUN_DIR/install.log"
finish
