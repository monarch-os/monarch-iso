#!/bin/bash

set -e

root=$(realpath "${BASH_SOURCE[0]%/*}/..")
build_iso="$root/builder/build-iso.sh"
build_package="$root/builder/build-monarch-package.sh"
offline_config="$root/configs/pacman-offline.conf"

grep -qF 'pacman-key --populate archlinux cachyos monarch' "$build_iso"
echo "ok - keyrings are populated in Monarch's required order"

if grep -Eq '^pacman --noconfirm -Sy|^pacman -Sy' "$build_iso" "$build_package"; then
  echo "not ok - a builder sync bypasses pacman-online.conf" >&2
  exit 1
fi
echo "ok - builder syncs do not fall back to the container pacman.conf"

grep -qF 'pacman --config /configs/pacman-online.conf --noconfirm -Syu' "$build_iso"
grep -qF 'pacman --config /configs/pacman-online.conf -Sy --noconfirm' "$build_package"
echo "ok - system and local-package syncs share Monarch's repository policy"

offline_siglevel=$(awk '
  /^\[offline\]$/ { offline=1; next }
  /^\[/ { offline=0 }
  offline && /^[[:space:]]*SigLevel[[:space:]]*=/ {
    sub(/^[^=]*=[[:space:]]*/, "")
    print
    exit
  }
' "$offline_config")
[[ $offline_siglevel == Never ]] || {
  echo "not ok - offline repo signature checks can race the live pacman keyring" >&2
  exit 1
}
echo "ok - offline pacstrap does not depend on the asynchronous live keyring"
