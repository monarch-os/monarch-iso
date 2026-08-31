#!/bin/bash

set -e

root=$(realpath "${BASH_SOURCE[0]%/*}/..")
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

make_package() {
  local name=$1
  mkdir -p "$tmp_dir/$name"
  printf 'pkgname = %s\npkgver = 1-1\n' "$name" >"$tmp_dir/$name/.PKGINFO"
  bsdtar -cf "$tmp_dir/$name-1-1-any.pkg.tar.zst" -C "$tmp_dir/$name" .PKGINFO
}

make_package monarch
make_package monarch-keyring

[[ $(bash "$root/builder/package-name.sh" "$tmp_dir/monarch-1-1-any.pkg.tar.zst") == monarch ]]
echo "ok - reads the runtime package name"

[[ $(bash "$root/builder/package-name.sh" "$tmp_dir/monarch-keyring-1-1-any.pkg.tar.zst") == monarch-keyring ]]
echo "ok - keeps monarch-keyring distinct from monarch"

if bash "$root/builder/package-name.sh" "$tmp_dir/missing.pkg.tar.zst" >/dev/null 2>&1; then
  echo "not ok - missing archive was accepted" >&2
  exit 1
fi
echo "ok - rejects a missing archive"
