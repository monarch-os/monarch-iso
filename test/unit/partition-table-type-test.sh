#!/bin/bash
# Probe the real table on images, even when udev/blkid cannot see it.

set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$root/configs/airootfs/usr/share/monarch-iso/disk-partitioning.sh"
for tool in parted blkid lsblk; do command -v "$tool" >/dev/null; done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Image files have no udev entry. Simulate that cached view for the blank case.
lsblk() { printf '%s' "${LSBLK_TYPE:-}"; return "${LSBLK_STATUS:-0}"; }
blkid() {
  if [[ -n ${BLKID_STATUS:-} ]]; then
    printf '%s' "${BLKID_TYPE:-}"
    return "$BLKID_STATUS"
  fi
  command blkid "$@"
}

for type in gpt msdos; do
  img="$work/$type.img"
  truncate -s 64M "$img"
  parted -s "$img" mklabel "$type" mkpart primary ext4 1MiB 20MiB
  [[ $(partition_table_type "$img") == "$type" ]]
  [[ $(BLKID_STATUS=2 partition_table_type "$img") == "$type" ]]
  echo "ok - $type is read from disk despite empty udev/blkid results"
done

img="$work/blank.img"
truncate -s 64M "$img"
[[ -z $(partition_table_type "$img") ]]
echo 'ok - a genuinely unlabeled disk is positively identified'
[[ $(BLKID_STATUS=0 BLKID_TYPE=gpt partition_table_type "$img") == gpt ]]
[[ $(LSBLK_TYPE=msdos partition_table_type "$img") == msdos ]]
echo 'ok - a witness table prevents a blank verdict'

for probe in 'BLKID_STATUS=4' 'BLKID_STATUS=8' 'LSBLK_STATUS=1'; do
  if (export "${probe?}"; partition_table_type "$img"); then
    echo "FAIL: $probe produced a blank verdict" >&2
    exit 1
  fi
  echo "ok - $probe cannot authorize mklabel"
done
if partition_table_type "$work/missing.img"; then
  echo 'FAIL: an unreadable disk was treated as blank' >&2
  exit 1
fi
echo 'ok - an unreadable disk is not a blank disk'

for mode in failed empty malformed unknown-io unknown-extra-row; do
  (
    parted() {
      case $mode in
        failed) return 1 ;;
        empty) return 0 ;;
        malformed) echo 'not a machine-readable table'; return 0 ;;
        unknown-io)
          echo 'Error: Input/output error during read' >&2
          printf 'BYT;\n/fake:64MB:file:512:512:unknown::;\n'
          return 1 ;;
        unknown-extra-row)
          printf 'BYT;\n/fake:64MB:file:512:512:unknown::;\n1:1B:2B:2B:::;\n'
          return 1 ;;
      esac
    }
    if partition_table_type "$img"; then
      echo "FAIL: $mode parted output was treated as a blank disk" >&2
      exit 1
    fi
    [[ $(BLKID_STATUS=0 BLKID_TYPE=gpt partition_table_type "$img") == gpt ]]
    echo "ok - $mode parted output is uncertain unless a witness finds a table"
  )
done

# Exercise the actual wizard functions, including their conditional call sites:
# errexit is disabled by Bash inside if, so failures must be handled explicitly.
configurator="$root/configs/airootfs/root/configurator"
source <(sed -n '/^requires_full_disk_install() {/,/^}/p; /^run_partition_decide() {/,/^}/p; /^run_partition_execute() {/,/^}/p' "$configurator")
disk="$img"
step() { :; }
say() { :; }
sleep() { :; }
partprobe() { :; }
detect_bitlocker() { :; }
detect_windows_esp() { :; }
abort() { echo "$*" >"$work/aborted"; exit 42; }
disk_abort_hook() { abort "$*"; }
monarch-wait-mirror-verify() { :; }
disk_step() { touch "$work/write-attempt"; exit 99; }

# Both ordinary picker outcomes still work with the real on-disk probes.
requires_full_disk_install
disk="$work/gpt.img"
if requires_full_disk_install; then
  echo 'FAIL: a GPT disk with free space was forced into full-disk mode' >&2
  exit 1
else
  [[ $? == 1 ]]
fi
echo 'ok - the mode picker distinguishes blank disks from GPT free space'

# Exercise a valid plan up to the confirmation (declined, so no writes).
clear_logo() { :; }
to_gb() { echo 40GB; }
gum() { return 1; }
lsblk() {
  if [[ $* == '-bdno SIZE '* ]]; then echo 42949672960; else return 0; fi
}
for type in blank gpt; do
  disk="$work/plan-$type.img"
  truncate -s 40G "$disk"
  if [[ $type == gpt ]]; then
    command parted -s "$disk" mklabel gpt mkpart old ext4 1MiB 20MiB
  fi
  if run_partition_decide; then
    echo 'FAIL: a declined confirmation was accepted' >&2
    exit 1
  else
    [[ $? == 1 ]]
  fi
  if [[ $type == blank ]]; then [[ $needs_mklabel == true ]]; else [[ $needs_mklabel == false ]]; fi
  [[ ! -f $work/write-attempt ]]
  echo "ok - a valid $type free-space plan still reaches confirmation without writes"
done

for function in requires_full_disk_install run_partition_decide; do
  if (
    partition_table_type() { return 1; }
    if "$function"; then :; fi
  ); then
    echo "FAIL: $function ignored a probe failure" >&2
    exit 1
  else
    [[ $? == 42 ]]
  fi
  [[ -s $work/aborted && ! -f $work/write-attempt ]]
  echo "ok - $function aborts on an uncertain table, even under if"
done

for function in requires_full_disk_install run_partition_decide; do
  if (
    partition_table_type() { echo gpt; }
    parted() { return 1; }
    if "$function"; then :; fi
  ); then
    echo "FAIL: $function ignored a free-space read failure" >&2
    exit 1
  else
    [[ $? == 42 ]]
  fi
  echo "ok - $function refuses an unreadable free-space map"
done

for mode in appeared unreadable; do
  if (
    needs_mklabel=true
    partition_table_type() { [[ $mode != unreadable ]] || return 1; echo gpt; }
    if run_partition_execute; then :; fi
  ); then
    echo 'FAIL: execution used a stale blank-disk verdict' >&2
    exit 1
  else
    [[ $? == 42 ]]
  fi
  [[ ! -f $work/write-attempt ]]
  echo "ok - $mode table stops execution before mklabel"
done
