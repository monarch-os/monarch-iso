#!/bin/bash
set -euo pipefail

root=$1
cache="$root/var/lib/monarch-iso"
mkdir -p "$cache"
mapfile -t kernels < <(find "$root/usr/lib/modules" -mindepth 2 -maxdepth 2 -name pkgbase | sort)
(( ${#kernels[@]} == 1 )) || exit 0
kernel=$(cat "${kernels[0]}")
version=$(basename "$(dirname "${kernels[0]}")")

python /configs/airootfs/usr/share/monarch-iso/orchestrator/prebuilt_uki.py "$root" "$kernel" \
  >"$cache/prebuilt-uki.json"
printf 'monarch.cmdline_room=%01780d\n' 0 >"$cache/cmdline"

# Use Monarch's own busybox/snapshot hooks; only omit host autodetection and KMS.
arch-chroot "$root" bash -c '
  source /etc/mkinitcpio.conf
  for config in /etc/mkinitcpio.conf.d/*.conf; do
    [[ ! -f $config ]] || source "$config"
  done
  filtered=()
  for hook in "${HOOKS[@]}"; do
    [[ $hook == autodetect || $hook == kms ]] || filtered+=("$hook")
  done
  HOOKS=("${filtered[@]}")
  declare -p MODULES BINARIES FILES HOOKS
  printf "COMPRESSION=zstd\n"
' >"$cache/mkinitcpio.conf"

if ! arch-chroot "$root" mkinitcpio -k "/usr/lib/modules/$version/vmlinuz" \
  -c /var/lib/monarch-iso/mkinitcpio.conf --cmdline /var/lib/monarch-iso/cmdline \
  -U /var/lib/monarch-iso/prebuilt-uki.efi; then
  rm -f "$cache/prebuilt-uki.efi"
fi
if [[ -f $cache/prebuilt-uki.efi ]] && (( $(stat -c %s "$cache/prebuilt-uki.efi") > 134217728 )); then
  echo "Prebuilt UKI exceeds 128 MiB; target will build its own" >&2
  rm -f "$cache/prebuilt-uki.efi"
fi
rm -f "$cache/cmdline" "$cache/mkinitcpio.conf"
