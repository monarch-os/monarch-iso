#!/bin/bash

set -e

root=$(realpath "${BASH_SOURCE[0]%/*}/..")
builder="$root/builder/build-iso.sh"
phases="$root/configs/airootfs/usr/share/monarch-iso/orchestrator/phases_impl.py"

grep -qF 'install/python.packages install/provisioning/setup-form.sh logo.txt' "$builder"
grep -qF 'cp "$runtime_share/logo.txt" "$build_cache_dir/airootfs/usr/share/monarch/logo.txt"' "$builder"
echo "ok - live image copies the packaged Monarch logo"

grep -qF 'ctx.target / "usr" / "share" / "monarch" / "default" / "limine" / filename' "$phases"
echo "ok - Limine templates come from the target runtime package"
