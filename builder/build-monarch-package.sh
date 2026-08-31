#!/bin/bash

set -e

offline_mirror_dir="$1"
[[ -n $offline_mirror_dir ]] || { echo "Usage: build-monarch-package.sh <offline-mirror-dir>" >&2; exit 1; }
[[ -d /monarch-source ]] || { echo "ERROR: /monarch-source not mounted" >&2; exit 1; }
[[ -n ${MONARCH_LOCAL_PKGVER:-} ]] || { echo "ERROR: MONARCH_LOCAL_PKGVER is required" >&2; exit 1; }
for package_name in monarch monarch-settings; do
  [[ -d /monarch-pkgs/pkgbuilds/$package_name ]] || {
    echo "ERROR: /monarch-pkgs/pkgbuilds/$package_name not found" >&2
    exit 1
  }
done

work_dir=/tmp/monarch-pkg-build
local_source_dir=/tmp/monarch-local-source
rm -rf "$work_dir" "$local_source_dir"
mkdir -p "$work_dir" "$local_source_dir"
cp -a /monarch-source/. "$local_source_dir/"
printf '%s\n' "$MONARCH_LOCAL_PKGVER" >"$local_source_dir/version"

if ! id builder &>/dev/null; then
  useradd -m -s /bin/bash builder
fi
echo 'builder ALL=(ALL) NOPASSWD: /usr/bin/pacman' >/etc/sudoers.d/99-monarch-pkg-builder
chmod 440 /etc/sudoers.d/99-monarch-pkg-builder

cp -a /monarch-pkgs/pkgbuilds/monarch /monarch-pkgs/pkgbuilds/monarch-settings "$work_dir/"
chown -R builder:builder "$work_dir"
pacman --config /configs/pacman-online.conf -Sy --noconfirm

for package_name in monarch-settings monarch; do
  su builder -c "
    cd '$work_dir/$package_name' &&
    PKGDEST='$work_dir' MONARCH_SRC='$local_source_dir' \
      makepkg --noconfirm --skippgpcheck --skipchecksums --nodeps -f
  "
done

mkdir -p "$offline_mirror_dir"
for package_name in monarch monarch-settings; do
  package_file=""
  while IFS= read -r candidate; do
    if [[ $(bash /builder/package-name.sh "$candidate" 2>/dev/null) == "$package_name" ]]; then
      package_file="$candidate"
      break
    fi
  done < <(find "$work_dir" -maxdepth 1 -type f -name '*.pkg.tar.*' -print)
  [[ -n $package_file ]] || { echo "ERROR: local $package_name package was not produced" >&2; exit 1; }

  while IFS= read -r cached_package; do
    if [[ $(bash /builder/package-name.sh "$cached_package" 2>/dev/null) == "$package_name" ]]; then
      rm -f "$cached_package"
    fi
  done < <(find "$offline_mirror_dir" -maxdepth 1 -type f -name '*.pkg.tar.*' -print)

  mv "$package_file" "$offline_mirror_dir/"
done
