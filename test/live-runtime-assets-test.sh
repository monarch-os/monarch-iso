#!/bin/bash

set -e

root=$(realpath "${BASH_SOURCE[0]%/*}/..")
builder="$root/builder/build-iso.sh"
phases="$root/configs/airootfs/usr/share/monarch-iso/orchestrator/phases_impl.py"

grep -qF 'install/monarch-preinstalls.packages' "$builder"
grep -qF 'assets/t2/firmware.py assets/t2/LICENSE bin/monarch-setup-t2-firmware logo.txt' "$builder"
grep -qF 'cp "$runtime_share/logo.txt" "$build_cache_dir/airootfs/usr/share/monarch/logo.txt"' "$builder"
grep -qF 'cp "$runtime_share/bin/monarch-setup-t2-firmware" "$build_cache_dir/airootfs/usr/local/bin/"' "$builder"
echo "ok - live image copies the packaged Monarch manifests and T2 extractor"

grep -qF 'ctx.target / "usr" / "share" / "monarch" / "default" / "limine" / filename' "$phases"
echo "ok - Limine templates come from the target runtime package"
