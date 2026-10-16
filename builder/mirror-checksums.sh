#!/bin/bash

set -euo pipefail

mirror=$(realpath -- "$1")
airootfs=$(realpath -- "$2")
metadata="$airootfs/usr/share/monarch-iso"
dropin="$airootfs/etc/systemd/system/monarch-mirror-verify.service.d"
mkdir -p "$metadata" "$dropin"

cd "$mirror"
shopt -s nullglob
packages=()
for package in *.pkg.tar.*; do
  [[ $package == *.sig ]] || packages+=("$package")
done
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
chmod 644 "$sums"
mv "$sums" "$metadata/offline-mirror.sha256"

# Allow 2 MiB/s plus ten minutes for slow media and startup contention.
timeout=$(( (bytes + 2097151) / 2097152 + 600 ))
printf '[Service]\nTimeoutStartSec=%s\n' "$timeout" >"$dropin/50-size-timeout.conf"
printf '%s\n' "$timeout" >"$metadata/offline-mirror.timeout"
echo "Mirror checksums: ${#files[@]} files, $((bytes >> 20)) MiB"
