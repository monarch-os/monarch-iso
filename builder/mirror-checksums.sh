#!/bin/bash

set -euo pipefail

mirror=$(realpath -- "$1")
airootfs=$(realpath -- "$2")
image_dir=$(realpath -- "${3:-$mirror}")
metadata="$airootfs/usr/share/monarch-iso"
dropin="$airootfs/etc/systemd/system/monarch-mirror-verify.service.d"
mkdir -p "$metadata" "$dropin"

cd "$mirror"
shopt -s nullglob
packages=()
for package in *.pkg.tar.*; do
  [[ $package == *.sig ]] || packages+=("$package")
done
if [[ -f $metadata/offline-mirror.shipped ]]; then
  mapfile -t packages <"$metadata/offline-mirror.shipped"
  for package in "${packages[@]}"; do
    [[ $package != */* && $package == *.pkg.tar.* && $package != *.sig && -f $package ]] || {
      echo "Invalid shipped package: $package" >&2
      exit 1
    }
  done
fi
if (( ${#packages[@]} == 0 )); then
  echo "Cannot checksum an empty offline mirror" >&2
  exit 1
fi
files=("${packages[@]}" offline.db offline.db.tar.gz offline.files offline.files.tar.gz)
bytes=0
for file in "${files[@]}"; do
  size=$(stat -L -c %s -- "$file")
  (( bytes += size )) || true
done

sums=$(mktemp "$metadata/offline-mirror.sha256.XXXXXX")
trap 'rm -f "$sums"' EXIT
sha256sum -- "${files[@]}" >"$sums"
image_path=$(cat "$metadata/root-image.path")
[[ $image_path == /run/archiso/bootmnt/*/x86_64/monarch-root.img.zst && $image_path != *..* ]] || exit 1
for suffix in '' .size; do
  file="$image_dir/monarch-root.img.zst$suffix"
  size=$(stat -L -c %s -- "$file")
  (( bytes += size )) || true
  hash=$(sha256sum -- "$file")
  printf '%s  %s%s\n' "${hash%% *}" "$image_path" "$suffix" >>"$sums"
done
chmod 644 "$sums"
mv "$sums" "$metadata/offline-mirror.sha256"

# Allow 2 MiB/s plus ten minutes for slow media and startup contention.
timeout=$(( (bytes + 2097151) / 2097152 + 600 ))
printf '[Service]\nTimeoutStartSec=%s\n' "$timeout" >"$dropin/50-size-timeout.conf"
printf '%s\n' "$timeout" >"$metadata/offline-mirror.timeout"
echo "Mirror checksums: ${#files[@]} files, $((bytes >> 20)) MiB"
