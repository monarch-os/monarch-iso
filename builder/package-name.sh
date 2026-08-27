#!/bin/bash

set -e

package_file=${1:-}
[[ -f $package_file ]] || { echo "Usage: package-name.sh <package-file>" >&2; exit 1; }

package_name=$(bsdtar -xOf "$package_file" .PKGINFO 2>/dev/null |
  sed -n 's/^pkgname = //p' | head -n 1)
[[ -n $package_name ]] || { echo "ERROR: cannot read pkgname from $package_file" >&2; exit 1; }

printf '%s\n' "$package_name"
