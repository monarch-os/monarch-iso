#!/bin/bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
for tool in qemu-img qemu-io sgdisk mkfs.fat mcopy mmd; do
  command -v "$tool" >/dev/null || { echo "skip - $tool required for free-space fixture"; exit 0; }
done
mkdir -p "$root/vm-saves"
work=$(mktemp -d "$root/vm-saves/free-space-fixture.XXXXXX")
trap 'rm -rf "$work"' EXIT
helper="$root/test/support/free-space-disk"
bash "$helper" create "$work/disk.qcow2" "$work/evidence"
bash "$helper" verify "$work/disk.qcow2" "$work/evidence"
echo "ok - existing partition metadata and contents survive fixture round-trip"
if bash "$helper" create "$work/disk.qcow2" "$work/evidence" 2>/dev/null; then
  echo "not ok - fixture creation overwrote an existing disk" >&2
  exit 1
fi
qemu-io -f qcow2 -c 'write -P 0x78 1048576 512' "$work/disk.qcow2" >/dev/null
if bash "$helper" verify "$work/disk.qcow2" "$work/evidence" 2>/dev/null; then
  echo "not ok - changed ESP passed preservation check" >&2
  exit 1
fi
echo "ok - a modified existing ESP fails preservation verification"
