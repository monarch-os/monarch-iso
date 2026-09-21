#!/bin/bash

set -euo pipefail

root=$(cd -- "${BASH_SOURCE[0]%/*}/../.." && pwd)
builder="$root/builder/build-iso.sh"
configurator="$root/configs/airootfs/root/configurator"
phases="$root/configs/airootfs/usr/share/monarch-iso/orchestrator/phases_impl.py"

grep -qF 'assets/t2/firmware.py assets/t2/LICENSE bin/monarch-setup-t2-firmware logo.txt' "$builder"
grep -qF 'cp "$runtime_share/bin/monarch-setup-t2-firmware" "$build_cache_dir/airootfs/usr/local/bin/"' "$builder"
echo "ok - ISO includes the pinned Monarch T2 extractor"

stage_line=$(grep -n '^stage_t2_firmware$' "$configurator" | tail -n 1 | cut -d: -f1)
write_line=$(grep -n '^write_install_user_files$' "$configurator" | tail -n 1 | cut -d: -f1)
(( stage_line < write_line ))
grep -qF 'monarch-setup-t2-firmware stage "$disk" "$archive"' "$configurator"
echo "ok - interactive installs stage firmware before partitioning"

prepare_line=$(grep -n '^def prepare_live' "$phases" | cut -d: -f1)
stage_line=$(grep -n '    _stage_t2_firmware(ctx)' "$phases" | head -n 1 | cut -d: -f1)
cleanup_line=$(grep -n 'cleaning up holders on install disk' "$phases" | head -n 1 | cut -d: -f1)
(( prepare_line < stage_line && stage_line < cleanup_line ))
grep -qF 'ctx.state.setdefault("extra_packages", []).append("apple-bcm-firmware-local")' "$phases"
echo "ok - unattended installs preserve firmware before disk cleanup and count the local package"
