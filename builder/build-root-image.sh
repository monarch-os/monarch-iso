#!/bin/bash
set -euo pipefail

config=$1
output=$2
shift 2
(( $# > 0 )) || { echo "Root image package list is empty" >&2; exit 1; }

work=$(mktemp -d /var/cache/monarch-root-image.XXXXXX)
mountpoint="$work/mount"
backing="$work/root.btrfs"
loop=""
hooks=()

cleanup() {
  local status=$?
  set +e
  for hook in "${hooks[@]}"; do
    rm -f "/etc/pacman.d/hooks/$hook"
    if [[ -e $work/$hook || -L $work/$hook ]]; then
      mv "$work/$hook" "/etc/pacman.d/hooks/$hook"
    fi
  done
  gpgconf --homedir "$mountpoint/monarch-root/etc/pacman.d/gnupg" --kill all 2>/dev/null
  if mountpoint -q "$mountpoint"; then
    umount -R "$mountpoint" || { echo "Leaving mounted root image at $work" >&2; return "$status"; }
  fi
  [[ -z $loop ]] || losetup -d "$loop"
  rm -rf "$work"
  return "$status"
}
trap cleanup EXIT

# There is no ESP during image creation; deployment hooks run on the target.
mkdir -p /etc/pacman.d/hooks
while IFS= read -r hook; do
  path="/etc/pacman.d/hooks/$hook"
  [[ ! -L $path || $(readlink "$path") != /dev/null ]] || continue
  if [[ -e $path || -L $path ]]; then mv "$path" "$work/$hook"; fi
  hooks+=("$hook")
  ln -s /dev/null "$path"
done </configs/airootfs/usr/share/monarch-iso/deferred-boot-hooks

truncate -s 24G "$backing"
[[ -e /dev/loop-control ]] || mknod /dev/loop-control c 10 237
loop=$(losetup --find | awk '{print $1}')
[[ $loop =~ ^/dev/loop[0-9]+$ ]] || { echo "No free loop device" >&2; exit 1; }
[[ -b $loop ]] || mknod "$loop" b 7 "${loop#/dev/loop}"
losetup "$loop" "$backing"
mkfs.btrfs -q -L monarch-root-image "$loop"
mkdir -p "$mountpoint"
mount -o compress-force=zstd:15 "$loop" "$mountpoint"
btrfs subvolume create "$mountpoint/monarch-root"
root="$mountpoint/monarch-root"

# Never distribute a shared pacman signing identity or machine identity.
sed '/^\[options\]/a CacheDir = /var/cache/monarch/mirror/offline' "$config" >"$work/pacman.conf"
pacstrap -C "$work/pacman.conf" -c -G -M "$root" "$@"
gpgconf --homedir "$root/etc/pacman.d/gnupg" --kill all 2>/dev/null || true
rm -rf "$root/etc/pacman.d/gnupg"
: >"$root/etc/machine-id"
rm -f "$root/var/lib/dbus/machine-id" "$root/etc/ssh/ssh_host_"* "$root/var/lib/systemd/random-seed"
rm -rf "$root/var/cache/pacman/pkg/"* "$root/etc/resolv.conf"
find "$root/var/log" -mindepth 1 ! -name pacman.log -delete

# This keyboard policy applies to every install, independently of its hardware.
arch-chroot "$root" bash /usr/share/monarch/install/hardware/fix-fkeys.sh
bash /builder/prebuild-uki.sh "$root"
pacman --root "$root" --dbpath "$root/var/lib/pacman" -Q >"$output.packages"

sync
used=$(btrfs filesystem usage --raw "$mountpoint" | awk '/^[[:space:]]+Used:/ {print $2; exit}')
[[ $used =~ ^[0-9]+$ ]] || { echo "Cannot determine root image usage" >&2; exit 1; }
size=$(( (used / 1048576 + 2048) * 1048576 ))
if ! btrfs filesystem resize "$size" "$mountpoint"; then
  size=$(stat -c %s "$backing")
fi
fstrim "$mountpoint" || true
sync
umount "$mountpoint"
losetup -d "$loop"
loop=""
truncate -s "$size" "$backing"
zstd -T2 -3 -f "$backing" -o "$output.tmp"
mv "$output.tmp" "$output"
printf '%s\n' "$size" >"$output.size"
