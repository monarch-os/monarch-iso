#!/bin/bash

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
builder="$root/builder/build-iso.sh"

grep -qF 'rm -rf "$build_cache_dir/airootfs/etc/systemd/system/cloud-init.target.wants"' "$builder"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' linux linux-firmware cloud-init >"$tmp/packages.x86_64"
mkdir -p "$tmp/airootfs/etc/mkinitcpio.d"

sed -n '/^arch_packages=(/,/^mapfile -t all_packages/{ /^mapfile -t all_packages/!p; }' \
  "$builder" >"$tmp/package-overrides.sh"
build_cache_dir=$tmp
source "$tmp/package-overrides.sh"

if grep -qxE 'linux|cloud-init' "$tmp/packages.x86_64"; then
  echo "not ok - live image retains the stock kernel or cloud-init" >&2
  exit 1
fi
grep -qxF linux-cachyos "$tmp/packages.x86_64"
grep -qxF linux-firmware "$tmp/packages.x86_64"
[[ ! -e $tmp/airootfs/etc/mkinitcpio.d/linux.preset ]]

echo "ok - live ISO removes cloud-init and its enabled units"
echo "ok - package overrides work without releng's removed linux.preset"
