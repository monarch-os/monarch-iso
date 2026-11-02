#!/bin/bash
# integration:opt-in

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }

qemu-img create -f qcow2 -b "$BASE_DISK" -F qcow2 "$RUN_DIR/run.qcow2" >/dev/null
cp "$BASE_OVMF" "$RUN_DIR/OVMF_VARS.4m.fd"
ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"
start_vm "$RUN_DIR/run.qcow2" "$RUN_DIR/serial.log" \
  -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0" \
  -device ide-cd,drive=cdrom0,bootindex=2
wait_for_ssh "$BOOT_TIMEOUT"

ssh_guest 'cat > /tmp/f1-layouts.py' <"$ROOT/test/support/f1-layouts.py"
check "Real Btrfs image deployment preserves protected and nested layouts" \
  ssh_sudo 'set -e
    mkdir -p /run/f1-media /run/f1-live
    mount -o ro /dev/sr0 /run/f1-media
    mount -o loop,ro /run/f1-media/arch/x86_64/airootfs.sfs /run/f1-live
    PYTHONPATH=/run/f1-live/usr/share/monarch-iso python /tmp/f1-layouts.py > /var/tmp/f1-layouts.log 2>&1'
ssh_sudo 'cat /var/tmp/f1-layouts.log' >"$RUN_DIR/layouts.log"
finish
