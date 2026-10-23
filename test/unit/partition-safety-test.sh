#!/bin/bash
# Real image files and injected read failures; no root, loop devices or real disks.

set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$root/configs/airootfs/usr/share/monarch-iso/disk-partitioning.sh"
command -v parted >/dev/null
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mib=$((1024 * 1024))

for mode in before-failed after-failed before-empty before-malformed; do
  (
    img="$work/$mode.img"
    truncate -s 64M "$img"
    command parted -s "$img" mklabel gpt mkpart old-esp fat32 1MiB 3MiB
    command parted -ms "$img" unit B print >"$work/$mode.before"
    parted() {
      if [[ " $* " == *' print '* || " $* " == *' print' ]]; then
        echo read >>"$work/$mode.reads"
        count=$(wc -l <"$work/$mode.reads")
        if [[ $mode == before-failed && $count == 1 || $mode == after-failed && $count == 2 ]]; then
          return 1
        fi
        if [[ $count == 1 && $mode == before-empty ]]; then return 0; fi
        if [[ $count == 1 && $mode == before-malformed ]]; then
          printf 'BYT;\n/fake:64MB:file:512:512:gpt::;\ngarbage\n'
          return 0
        fi
      fi
      [[ " $* " != *' mkpart '* ]] || touch "$work/$mode.mkpart"
      command parted "$@"
    }
    # Explicit status checking must work even without the caller's pipefail.
    set +o pipefail
    if create_partition "$img" "$((8 * mib))" "$((10 * mib))" fat32 MONARCH_EFI; then
      echo "FAIL: $mode accepted an uncertain partition read" >&2
      exit 1
    fi
    [[ -z $created_partition_number && ${#created_parts[@]} == 0 ]]
    rollback_created_parts "$img"
    if [[ $mode == after-failed ]]; then
      # The new partition is left unclaimed rather than guessing what to erase.
      [[ $(command parted -ms "$img" print | tail -n +3 | cut -d: -f1 | paste -sd' ' -) == '1 2' ]]
    else
      [[ ! -f $work/$mode.mkpart ]]
      command parted -ms "$img" unit B print >"$work/$mode.after"
      cmp "$work/$mode.before" "$work/$mode.after"
    fi
    echo "ok - $mode never claims or rolls back the existing ESP"
  )
done

# Net count +1 is not enough: two additions with a removal are ambiguous.
# Mock only the external table producer; run the real list parser and delta.
for mode in no-addition two-additions removal-and-two-additions duplicate-number; do
  (
    parted() {
      if [[ " $* " == *' print '* || " $* " == *' print' ]]; then
        printf 'BYT;\n/fake:64MB:file:512:512:gpt::;\n'
        if [[ ! -f $work/$mode.reads ]]; then
          touch "$work/$mode.reads"
          numbers='1 2'
        else
          case $mode in
            no-addition) numbers='1 2' ;;
            two-additions) numbers='1 2 3 4' ;;
            removal-and-two-additions) numbers='2 3 4' ;;
            duplicate-number) numbers='1 2 3 3' ;;
          esac
        fi
        for number in $numbers; do printf '%s:1B:2B:2B:fat32:test:;\n' "$number"; done
      else
        [[ " $* " != *' name '* ]] || touch "$work/$mode.renamed"
      fi
    }
    partprobe() { :; }
    udevadm() { :; }
    if create_partition /fake 100 200 fat32 MONARCH_EFI; then
      echo "FAIL: $mode accepted an ambiguous delta" >&2
      exit 1
    fi
    [[ -z $created_partition_number && ${#created_parts[@]} == 0 && ! -f $work/$mode.renamed ]]
    echo "ok - $mode is rejected before claiming a rollback partition"
  )
done

# Lexicographic, not numeric, ordering is required by comm (2 sorts after 10).
(
  parted() {
    if [[ " $* " == *' print '* || " $* " == *' print' ]]; then
      printf 'BYT;\n/fake:64MB:file:512:512:gpt::;\n'
      printf '2:1B:2B:2B:fat32:old:;\n10:3B:4B:2B:fat32:old:;\n'
      if [[ -f $work/sorted.reads ]]; then printf '11:5B:6B:2B:fat32:new:;\n'; fi
      touch "$work/sorted.reads"
    fi
  }
  partprobe() { :; }
  udevadm() { :; }
  partition_size_bytes() { echo 100; }
  create_partition /fake 100 200 fat32 MONARCH_EFI
  [[ $created_partition_number == 11 && ${created_parts[*]} == 11 ]]
  echo 'ok - multi-digit partition numbers use the same lexical order'
)
