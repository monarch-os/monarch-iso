#!/bin/bash
set -euo pipefail

offline_mirror_dir=$1
recipe=/monarch-pkgs/pkgbuilds/monarch-systemd-stub
[[ -f $recipe/PKGBUILD ]] || { echo "ERROR: Monarch stub recipe missing" >&2; exit 1; }
work_dir=$(mktemp -d /tmp/monarch-stub-build.XXXXXX)
trap 'rm -rf "$work_dir"' EXIT
cp -a "$recipe/." "$work_dir/"
chown -R builder:builder "$work_dir"
pacman --config /configs/pacman-online.conf -S --needed --noconfirm \
  meson ninja python-jinja python-pyelftools gperf libcap util-linux
su builder -c "cd '$work_dir' && makepkg --noconfirm --nodeps"
mapfile -t packages < <(find "$work_dir" -maxdepth 1 -type f -name 'monarch-systemd-stub-*.pkg.tar.zst')
(( ${#packages[@]} == 1 )) || { echo "ERROR: expected one Monarch stub package" >&2; exit 1; }
while IFS= read -r candidate; do
  if [[ $(bash /builder/package-name.sh "$candidate") == monarch-systemd-stub ]]; then
    rm -f "$candidate"
  fi
done < <(find "$offline_mirror_dir" -maxdepth 1 -type f -name '*.pkg.tar.*')
mv "${packages[0]}" "$offline_mirror_dir/"
