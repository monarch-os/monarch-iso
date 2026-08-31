#!/bin/bash

set -euo pipefail

source_dir=${1:-}
[[ -d $source_dir ]] || { echo "Source checkout not found: $source_dir" >&2; exit 1; }

version=$(git -C "$source_dir" describe --long --tags 2>/dev/null |
  sed 's/^v//;s/-/.r/;s/-/./') ||
  version="0.r$(git -C "$source_dir" rev-list --count HEAD).$(git -C "$source_dir" rev-parse --short HEAD)"

[[ $version =~ ^[0-9A-Za-z.+_]+$ ]] || {
  echo "Invalid package version derived from $source_dir: $version" >&2
  exit 1
}

printf '%s\n' "$version"
