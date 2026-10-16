#!/bin/bash

set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/mirror" "$WORK/root"
mirror="$WORK/mirror"
metadata="$WORK/root/usr/share/monarch-iso"
printf 'package payload\n' >"$mirror/runtime-1-1-x86_64.pkg.tar.zst"
printf 'settings payload\n' >"$mirror/settings-1-1-any.pkg.tar.xz"
printf 'signature\n' >"$mirror/runtime-1-1-x86_64.pkg.tar.zst.sig"
printf 'database\n' >"$mirror/offline.db.tar.gz"
printf 'file list\n' >"$mirror/offline.files.tar.gz"
ln -s offline.db.tar.gz "$mirror/offline.db"
ln -s offline.files.tar.gz "$mirror/offline.files"

bash "$ROOT/builder/mirror-checksums.sh" "$mirror" "$WORK/root"
sums="$metadata/offline-mirror.sha256"
[[ $(wc -l <"$sums") == 6 ]]
(cd "$mirror" && sha256sum --check --strict --quiet "$sums")
[[ $(cat "$metadata/offline-mirror.timeout") == 601 ]]
grep -Fx 'TimeoutStartSec=601' "$WORK/root/etc/systemd/system/monarch-mirror-verify.service.d/50-size-timeout.conf"

for corrupt in runtime-1-1-x86_64.pkg.tar.zst offline.db.tar.gz; do
  cp "$mirror/$corrupt" "$WORK/original"
  printf 'corruption\n' >>"$mirror/$corrupt"
  if (cd "$mirror" && sha256sum --check --strict --quiet "$sums") >"$WORK/out" 2>&1; then
    echo "Corruption was accepted: $corrupt" >&2
    exit 1
  fi
  grep -F "$corrupt" "$WORK/out"
  mv "$WORK/original" "$mirror/$corrupt"
done
rm "$mirror/settings-1-1-any.pkg.tar.xz"
if (cd "$mirror" && sha256sum --check --strict --quiet "$sums") >"$WORK/out" 2>&1; then
  echo "Missing package was accepted" >&2
  exit 1
fi
mkdir "$WORK/empty"
if bash "$ROOT/builder/mirror-checksums.sh" "$WORK/empty" "$WORK/root" >"$WORK/out" 2>&1; then
  echo "Empty mirror was accepted" >&2
  exit 1
fi
rm "$mirror/offline.db.tar.gz"
if bash "$ROOT/builder/mirror-checksums.sh" "$mirror" "$WORK/root" >"$WORK/out" 2>&1; then
  echo "Missing repository database was accepted" >&2
  exit 1
fi

source "$ROOT/configs/airootfs/usr/local/bin/monarch-wait-mirror-verify"
MIRROR_SUMS=$sums
MIRROR_TIMEOUT="$metadata/offline-mirror.timeout"

timeout() { shift; "$@"; }
sleep() { SECONDS=$((SECONDS + 100)); }
journalctl() { echo 'runtime-1-1-x86_64.pkg.tar.zst: FAILED'; }
systemctl() {
  if [[ $1 == "start" ]]; then
    [[ $scenario != "start-failure" ]]
    return
  fi
  local state=active result=success status=0 loaded=loaded substate=exited count
  count=$(cat "$WORK/calls")
  printf '%s\n' "$((count + 1))" >"$WORK/calls"
  case $scenario in
    empty) return 0 ;;
    unavailable) return 1 ;;
    retry) (( count > 0 )) || return 1 ;;
    pending) (( count > 0 )) || { state=activating; substate=start; } ;;
    inactive) state=inactive ;;
    stuck) state=activating; substate=start ;;
    stopping) state=deactivating; substate=stop-sigterm ;;
    corrupt) state=failed; result=exit-code; status=1 ;;
    slow) state=failed; result=timeout; status=15 ;;
    missing) loaded=not-found ;;
    partial) echo 'LoadState=loaded'; return ;;
    bad-verdict) status=1 ;;
  esac
  printf 'LoadState=%s\nActiveState=%s\nSubState=%s\nResult=%s\nExecMainStatus=%s\n' \
    "$loaded" "$state" "$substate" "$result" "$status"
}

for scenario in success pending retry; do
  printf '0\n' >"$WORK/calls"
  wait_for_mirror >"$WORK/out" 2>&1 || { cat "$WORK/out"; exit 1; }
  grep -F 'mirror verified' "$WORK/out"
done
for scenario in start-failure empty unavailable inactive stuck stopping corrupt slow missing partial bad-verdict; do
  printf '0\n' >"$WORK/calls"
  if wait_for_mirror >"$WORK/out" 2>&1; then
    echo "Invalid verification verdict was accepted: $scenario" >&2
    exit 1
  fi
  if [[ $scenario == "corrupt" ]]; then
    grep -F 'runtime-1-1-x86_64.pkg.tar.zst: FAILED' "$WORK/out"
  fi
done
scenario=success
for invalid in '' zero -1 0 599 '600;exit 0'; do
  printf '%s\n' "$invalid" >"$MIRROR_TIMEOUT"
  if wait_for_mirror >"$WORK/out" 2>&1; then
    echo "Invalid timeout was accepted: $invalid" >&2
    exit 1
  fi
done
printf '601\n' >"$MIRROR_TIMEOUT"
rm "$MIRROR_SUMS"
if wait_for_mirror >"$WORK/out" 2>&1; then
  echo "Absent checksum manifest was accepted" >&2
  exit 1
fi

echo 'Mirror checksums and verification verdicts passed'
