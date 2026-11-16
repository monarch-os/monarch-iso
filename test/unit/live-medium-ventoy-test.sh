#!/bin/bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
HOOK="$ROOT/configs/airootfs/etc/initcpio/hooks/udev"
CONF="$ROOT/configs/airootfs/etc/mkinitcpio.conf.d/archiso.conf"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# Omarchy 1cd7462 cases: device-mapper media need no by-uuid symlink.
run_case() {
  local name=$1 expected=$2 found=$3 ventoy=$4 calls
  shift 4
  rm -rf "$work/ventoy"
  [[ $ventoy == yes ]] && mkdir "$work/ventoy"
  calls=$(
    env -i PATH="$PATH" HOOK="$HOOK" WORK="$work" FOUND="$found" "$@" bash -c '
      : >"$WORK/calls"
      echo 0 >"$WORK/looks"
      msg() { :; }
      getarg() { [[ $1 == rdinit ]] && echo "${RDINIT:-}"; }
      sleep() { :; }
      udevadm() {
        [[ $1 == trigger ]] && return 0
        echo "$1" >>"$WORK/calls"
        [[ $1 == wait ]] && return 1
        return 0
      }
      blkid() {
        local looks=$(($(<"$WORK/looks") + 1))
        echo "$looks" >"$WORK/looks"
        [[ $FOUND == yes ]] && ((looks >= 3))
      }
      archisosearchuuid=${archisosearchuuid:-}
      archiso_nbd_srv=${archiso_nbd_srv:-} archiso_nfs_srv=${archiso_nfs_srv:-} archiso_http_srv=${archiso_http_srv:-}
      . <(sed "s|/ventoy|$WORK/ventoy|g" "$HOOK")
      run_hook
      echo "$(paste -sd" " "$WORK/calls")|$(<"$WORK/looks")"
    '
  )
  if [[ $calls == "$expected" ]]; then
    echo "ok: $name"
  else
    echo "FAIL: $name: '$calls', expected '$expected'"
    failures=$((failures + 1))
  fi
}

run_case "medium found without a by-uuid link" "|3" yes no archisosearchuuid=fixture
run_case "missing medium falls back to settle" "settle|300" no no archisosearchuuid=fixture
run_case "Ventoy normal mode does not wait" "|0" no yes archisosearchuuid=fixture
run_case "Ventoy GRUB2 waits for uevents" "|3" yes yes archisosearchuuid=fixture RDINIT=/vtoy/vtoy
for transport in nbd nfs http; do
  run_case "PXE $transport retains settle" "settle|0" yes no archisosearchuuid=fixture "archiso_${transport}_srv=10.0.2.2"
done
run_case "no UUID retains settle" "settle|0" yes no

modules=$(bash -c '. "$1"; echo " ${MODULES[*]} "' _ "$CONF")
if [[ $modules == *" loop "* ]]; then
  echo "ok: live initramfs loads loop"
else
  echo "FAIL: live initramfs does not load loop"
  failures=$((failures + 1))
fi
((failures == 0)) || exit 1
