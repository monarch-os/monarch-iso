#!/bin/bash

set -euo pipefail
export LC_ALL=C

root=$(realpath "${BASH_SOURCE[0]%/*}/../..")
source "$root/builder/local-package-dependencies.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/packages" "$tmp/db/sync" "$tmp/archive"

package() {
  local name=$1 version=$2
  shift 2
  printf 'pkgname = %s\npkgver = %s\narch = any\npkgdesc = fixture\nsize = 0\n' "$name" "$version" >"$tmp/archive/.PKGINFO"
  printf '%s\n' "$@" >>"$tmp/archive/.PKGINFO"
  bsdtar -cf "$tmp/packages/$name-$version-any.pkg.tar.zst" --zstd -C "$tmp/archive" .PKGINFO
}

package monarch 2:3.0-2 'depend = monarch-settings>=2' 'depend = local-api>=4' \
  'depend = external>=2' 'depend = external<4' 'depend = unversioned-api>=1' \
  'optdepend = ignored: optional' 'makedepend = ignored-build'
runtime_package="$tmp/packages/monarch-2:3.0-2-any.pkg.tar.zst"
package monarch-settings 2-1 'provides = local-api=4' 'provides = unversioned-api' \
  'depend = monarch>=2:3.0-1' 'depend = settings-only'
settings_package="$tmp/packages/monarch-settings-2-1-any.pkg.tar.zst"
package monarch 99-1 'depend = stale-dependency'
load_local_package_dependencies "$runtime_package" "$settings_package"
[[ ${local_depends[*]} == 'external>=2 external<4 unversioned-api>=1 settings-only' ]]
echo 'ok - exact archives, both dependency sets, constraints and unversioned provides'

for dependency in monarch 'monarch=2:3.0-2' 'monarch>2:3.0-1' 'monarch<2:3.0-3' \
  'monarch>=2:3.0-2' 'monarch<=2:3.0-2' local-api 'local-api=4' unversioned-api; do
  local_dependency_satisfied "$dependency"
done
for dependency in 'monarch>2:3.0-2' 'monarch<2:3.0-2' 'monarch=3.0-2' \
  'local-api>=5' 'unversioned-api>=1' missing; do
  if local_dependency_satisfied "$dependency"; then
    echo "unexpectedly satisfied $dependency" >&2
    exit 1
  fi
done
echo 'ok - version comparisons include epochs, pkgrel and all operators'

if load_local_package_dependencies "$runtime_package" "$tmp/missing" 2>"$tmp/error"; then
  exit 1
fi
grep -q 'cannot read .PKGINFO' "$tmp/error"
package malformed ''
if load_local_package_dependencies "$tmp/packages/malformed--any.pkg.tar.zst" 2>"$tmp/error"; then
  exit 1
fi
grep -q 'missing pkgname or pkgver' "$tmp/error"
echo 'ok - unreadable or incomplete metadata fails closed'

sed -n '/^source \/builder\/local-package-dependencies.sh/,/^mapfile -t required_package_files/{ /^mapfile -t required_package_files/!p; }' \
  "$root/builder/build-iso.sh" |
  sed -e "s|/builder/|$root/builder/|g" -e "s|/tmp/offlinedb|$tmp/db|g" >"$tmp/transaction.sh"
(
  package monarch 2:3.0-3 'provides = monarch-settings=3.0' 'provides = local-api=4' \
    'provides = unversioned-api' 'depend = external>=2' 'depend = external<4' \
    'depend = unversioned-api>=1' 'depend = settings-only'
  runtime_package="$tmp/packages/monarch-2:3.0-3-any.pkg.tar.zst"
  pacman() {
    printf '%s\n' "$@" >>"$tmp/calls"
    if [[ " $* " == *' --print '* ]]; then
      if [[ ${fail_resolution:-0} == 1 ]]; then
        echo 'missing dependency from stdout'
        echo 'pacman stderr detail' >&2
        return 1
      fi
      echo 'external-3-1-any.pkg.tar.zst'
    fi
  }
  all_packages=(monarch monarch-settings local-api listed)
  offline_mirror_dir="$tmp/packages"
  source "$tmp/transaction.sh"
  [[ ${all_packages[*]} == 'external<4 external>=2 listed settings-only unversioned-api>=1' ]]
  [[ $(grep -cFx 'external>=2' "$tmp/calls") == 2 ]]
  [[ $(grep -cFx 'settings-only' "$tmp/calls") == 2 ]]
  [[ $(grep -cFx 'local-api=4' "$tmp/calls") == 2 ]]
  [[ $(grep -cFx -- '--assume-installed' "$tmp/calls") == 8 ]]
  ! grep -qxE 'monarch|monarch-settings|local-api' "$tmp/calls"
  fail_resolution=1
  if (source "$tmp/transaction.sh") >"$tmp/output" 2>"$tmp/error"; then
    exit 1
  fi
  grep -q 'missing dependency from stdout' "$tmp/error"
  grep -q 'pacman stderr detail' "$tmp/error"
  grep -q 'could not resolve the package files' "$tmp/error"
)
echo 'ok - unified package download and prune resolution share dependencies and providers; failures retain diagnostics'

sed -n '/^resolve_expected_packages() {/,/^}/p' "$root/builder/build-iso.sh" >"$tmp/expected.sh"
(
  source "$tmp/expected.sh"
  pacman() { echo 'target dependency from stdout'; echo 'target stderr detail' >&2; return 1; }
  build_cache_dir=$tmp expected_packages_root=$tmp
  if resolve_expected_packages monarch >"$tmp/output" 2>"$tmp/error"; then
    exit 1
  fi
  [[ ! -s $tmp/output ]]
  grep -q 'target dependency from stdout' "$tmp/error"
  grep -q 'target stderr detail' "$tmp/error"
  grep -q 'could not resolve expected target packages' "$tmp/error"
)
echo 'ok - expected-count resolution fails without emitting a partial count and retains diagnostics'

load_local_package_dependencies "$runtime_package" "$settings_package"
package external 3-1 'depend = transitive' 'depend = local-api>=4'
package transitive 1-1
package settings-only 1-1
package alternate-provider 1-1 'provides = unversioned-api=1'
repo-add "$tmp/repo.db.tar.gz" "$tmp/packages/external-3-1-any.pkg.tar.zst" \
  "$tmp/packages/transitive-1-1-any.pkg.tar.zst" \
  "$tmp/packages/settings-only-1-1-any.pkg.tar.zst" \
  "$tmp/packages/alternate-provider-1-1-any.pkg.tar.zst" >/dev/null 2>&1
cp "$tmp/repo.db.tar.gz" "$tmp/db/sync/fixture.db"
cat >"$tmp/pacman.conf" <<EOF
[options]
Architecture = auto
SigLevel = Never
[fixture]
Server = file://$tmp/packages
EOF
resolve() {
  pacman --config "$tmp/pacman.conf" --dbpath "$tmp/db" --noconfirm \
    -S --print --print-format '%f' "$@"
}
resolved=$(resolve "${local_pacman_args[@]}" "${local_depends[@]}")
for name in external-3-1 transitive-1-1 settings-only-1-1 alternate-provider-1-1; do
  grep -qx "$name-any.pkg.tar.zst" <<<"$resolved"
done
[[ $(wc -l <<<"$resolved") == 4 ]]
if resolve "${local_pacman_args[@]}" 'external>=4' >"$tmp/output" 2>"$tmp/error"; then
  exit 1
fi
echo 'ok - real pacman resolves transitive closure and enforces external versions'

printf '%s\n' "$resolved" "${runtime_package##*/}" "${settings_package##*/}" |
  bash "$root/builder/prune-offline-mirror.sh" "$tmp/packages" >/dev/null
[[ -f $runtime_package && -f $settings_package ]]
[[ ! -e $tmp/packages/monarch-99-1-any.pkg.tar.zst ]]
[[ -f $tmp/packages/transitive-1-1-any.pkg.tar.zst ]]
echo 'ok - pruning retains dependency closure and exact local packages'

repo-add "$tmp/repo.db.tar.gz" "$runtime_package" "$settings_package" >/dev/null 2>&1
cp "$tmp/repo.db.tar.gz" "$tmp/db/sync/fixture.db"
resolve monarch monarch-settings >/dev/null
package monarch-settings 2-1 'depend = monarch>2:3.0-2'
if load_local_package_dependencies "$runtime_package" "$settings_package" 2>"$tmp/error"; then
  exit 1
fi
grep -q 'local packages do not satisfy monarch>2:3.0-2' "$tmp/error"
repo-add "$tmp/repo.db.tar.gz" "$settings_package" >/dev/null 2>&1
cp "$tmp/repo.db.tar.gz" "$tmp/db/sync/fixture.db"
if resolve monarch monarch-settings >"$tmp/output" 2>"$tmp/error"; then
  exit 1
fi
echo 'ok - incompatible local pair fails before download and in final real-archive resolution'
