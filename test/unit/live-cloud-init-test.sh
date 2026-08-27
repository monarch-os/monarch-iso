#!/bin/bash

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
builder="$root/builder/build-iso.sh"

grep -qF "'/^(linux|broadcom-wl|cloud-init)$/d'" "$builder"
grep -qF 'rm -rf "$build_cache_dir/airootfs/etc/systemd/system/cloud-init.target.wants"' "$builder"

echo "ok - live ISO removes cloud-init and its enabled units"
