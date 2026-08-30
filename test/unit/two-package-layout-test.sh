#!/bin/bash

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
monarch_root=${MONARCH_PATH:-$root/../monarch}
monarch_pkgs_root=${MONARCH_PKGS_PATH:-$root/../monarch-pkgs}
runtime_pkgbuild="$monarch_pkgs_root/pkgbuilds/monarch/PKGBUILD"
settings_pkgbuild="$monarch_pkgs_root/pkgbuilds/monarch-settings/PKGBUILD"

[[ -f $runtime_pkgbuild ]]
[[ -f $settings_pkgbuild ]]

grep -qF '"monarch-settings=${pkgver}"' "$runtime_pkgbuild"

noctalia_package=$(sed -n '/^noctalia/p' "$monarch_root/install/monarch-base.packages")
[[ -n $noctalia_package ]]
grep -qF "'$noctalia_package'" "$runtime_pkgbuild" || {
  echo "runtime dependency does not match offline Noctalia package: $noctalia_package" >&2
  exit 1
}

grep -qF 'cp -a "$MONARCH_SRC/." "$srcdir/monarch/"' "$runtime_pkgbuild"
grep -qF 'cp -a "$MONARCH_SRC/." "$srcdir/monarch/"' "$settings_pkgbuild"
grep -qF 'config/. "$pkgdir/etc/skel/.config/"' "$settings_pkgbuild"
grep -qF 'config/. "$pkgdir/usr/share/monarch/config/"' "$settings_pkgbuild"
grep -qF 'default/systemd/user/monarch-crash-watch.service' "$settings_pkgbuild"
if grep -qF -- '--no-preserve=ownership' "$runtime_pkgbuild" "$settings_pkgbuild"; then
  echo "package recipes must preserve the reference local-source workflow" >&2
  exit 1
fi

[[ -x $monarch_root/bin/monarch-dns ]]
[[ -f $monarch_root/etc/sudoers.d/monarch-dns ]]
[[ ! -d $monarch_pkgs_root/pkgbuilds/monarch-dns ]]
! grep -qxF monarch-dns "$monarch_root/install/monarch-base.packages"
if grep -qE "^(provides|conflicts|replaces)=\('monarch-dns'\)" "$runtime_pkgbuild"; then
  echo "runtime still carries compatibility metadata for retired monarch-dns" >&2
  exit 1
fi

grep -qF 'for package_name in monarch-settings monarch' "$root/builder/build-monarch-package.sh"
grep -qF 'grep -Fxv -e monarch -e monarch-settings' "$root/builder/build-iso.sh"
grep -qF '((expected_packages += 2))' "$root/builder/build-iso.sh"
grep -qF "printf '%s\\n' monarch-keyring monarch monarch-settings" "$root/builder/build-iso.sh"

target_block=$(sed -n '/mapfile -t target_packages/,/^)/p' "$root/builder/build-iso.sh")
if grep -qF '/builder/archinstall.packages' <<<"$target_block"; then
  echo "live-only archinstall packages leak into the target package count" >&2
  exit 1
fi

if grep -qE 'install/(preflight|packaging)|helpers/all\.sh' "$monarch_root/install.sh"; then
  echo "install.sh still invokes the retired installer pipeline" >&2
  exit 1
fi
grep -qF 'exec monarch-apply-system "$@"' "$monarch_root/install.sh"

echo "ok - Monarch runtime and settings are built and counted as two packages"
