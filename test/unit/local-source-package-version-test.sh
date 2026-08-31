#!/bin/bash

set -euo pipefail

root=$(realpath "${BASH_SOURCE[0]%/*}/../..")
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

git -C "$fixture" init -q
git -C "$fixture" config user.name Test
git -C "$fixture" config user.email test@example.com
printf '0.12.0\n' >"$fixture/version"
git -C "$fixture" add version
git -C "$fixture" commit -qm initial
git -C "$fixture" tag v0.12.0

printf 'base\n' >"$fixture/change"
git -C "$fixture" add change
git -C "$fixture" commit -qm base
published_version=$("$root/builder/source-package-version.sh" "$fixture")

printf 'feature\n' >>"$fixture/change"
git -C "$fixture" commit -qam feature
local_version=$("$root/builder/source-package-version.sh" "$fixture")

(( $(vercmp "$local_version" "$published_version") > 0 )) || {
  echo "not ok - local feature package would be replaced by the base package" >&2
  exit 1
}

echo "ok - a local feature checkout produces a newer package version than its base"

grep -qF 'MONARCH_LOCAL_PKGVER=$("${BASH_SOURCE[0]%/*}/../builder/source-package-version.sh" "$LOCAL_MONARCH_PATH")' \
  "$root/bin/monarch-iso-make"
grep -qF 'printf '\''%s\n'\'' "$MONARCH_LOCAL_PKGVER" >"$local_source_dir/version"' \
  "$root/builder/build-monarch-package.sh"

echo "ok - the host-derived version reaches the temporary package source"
