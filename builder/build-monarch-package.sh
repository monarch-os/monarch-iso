#!/bin/bash

set -e

offline_mirror_dir="$1"
[[ -n $offline_mirror_dir ]] || { echo "Usage: build-monarch-package.sh <offline-mirror-dir>" >&2; exit 1; }
[[ -d /monarch-source ]] || { echo "ERROR: /monarch-source not mounted" >&2; exit 1; }
[[ -n ${MONARCH_LOCAL_PKGVER:-} ]] || { echo "ERROR: MONARCH_LOCAL_PKGVER is required" >&2; exit 1; }
[[ -f /monarch-pkgs/pkgbuilds/monarch/PKGBUILD ]] || {
  echo "ERROR: /monarch-pkgs/pkgbuilds/monarch/PKGBUILD not found" >&2
  exit 1
}

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

cp -a /monarch-pkgs/pkgbuilds/monarch "$work_dir/"
chown -R builder:builder "$work_dir"
pacman --config /configs/pacman-online.conf -Sy --noconfirm

su builder -c "
  cd '$work_dir/monarch' &&
  PKGDEST='$work_dir' MONARCH_SRC='$local_source_dir' \
    makepkg --noconfirm --skippgpcheck --skipchecksums --nodeps -f
"

mkdir -p "$offline_mirror_dir"
package_file=""
while IFS= read -r candidate; do
  if [[ $(bash /builder/package-name.sh "$candidate" 2>/dev/null) == "monarch" ]]; then
    package_file="$candidate"
    break
  fi
done < <(find "$work_dir" -maxdepth 1 -type f -name '*.pkg.tar.*' -print)
[[ -n $package_file ]] || { echo "ERROR: local monarch package was not produced" >&2; exit 1; }

while IFS= read -r cached_package; do
  case $(bash /builder/package-name.sh "$cached_package" 2>/dev/null) in
    monarch | monarch-settings) rm -f "$cached_package" ;;
  esac
done < <(find "$offline_mirror_dir" -maxdepth 1 -type f -name '*.pkg.tar.*' -print)

mv "$package_file" "$offline_mirror_dir/"
