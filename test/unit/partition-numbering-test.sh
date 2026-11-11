#!/bin/bash
#
# create_partition() must report the number parted actually assigned, never a
# predicted one. The regression this pins: the configurator used to compute
# "highest existing partition + 1", while parted fills the lowest free GPT
# slot. Any disk whose numbering has a hole — what deleting a partition to
# free space leaves behind — then had every later command (cryptsetup, mkfs,
# mount) pointed at device nodes that did not exist, surfacing much later as
# "free-space install: /mnt is not a mountpoint".
#
# parted operates on image files directly, so this needs no root, no loop
# devices, and no real disk.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
LIB="$ROOT/configs/airootfs/usr/share/monarch-iso/disk-partitioning.sh"

if ! command -v parted >/dev/null 2>&1; then
  echo "SKIP: parted is not installed"
  exit 0
fi

# shellcheck source=../configs/airootfs/usr/share/monarch-iso/disk-partitioning.sh
source "$LIB"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

IMG="$WORK/disk.img"
MIB=$((1024 * 1024))
failures=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ $expected == "$actual" ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s: expected %s, got %s\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

# parted's end position is inclusive, so partitions laid back to back overlap
# by a sector and are refused. Leave a MiB between them.
mkpart_mib() {
  parted --script "$IMG" mkpart "$1" "$2" "$(($3 * MIB))B" "$(($4 * MIB))B"
}

# A disk with holes: four partitions, then delete the middle two. Slots 2 and
# 3 are free while the highest number in use is 4 — the shape of the reported
# failure, where the user deleted a partition to make room.
build_holey_disk() {
  rm -f "$IMG"
  truncate -s 4G "$IMG"
  parted --script "$IMG" mklabel gpt
  mkpart_mib one ext4 1 200
  mkpart_mib two ext4 201 400
  mkpart_mib three ext4 401 600
  mkpart_mib four ext4 601 800
  parted --script "$IMG" rm 2
  parted --script "$IMG" rm 3
  created_parts=()
}

echo "==> numbering on a disk with holes"
build_holey_disk
check "existing numbers" "1 4" "$(partition_numbers "$IMG" | sort | tr '\n' ' ' | sed 's/ $//')"
# Witness bytes model Windows/foreign UKI data on the two protected partitions.
printf 'Windows EFI witness' | dd of="$IMG" bs=1 seek="$((2 * MIB))" conv=notrunc status=none
printf 'foreign UKI witness' | dd of="$IMG" bs=1 seek="$((602 * MIB))" conv=notrunc status=none
protected_bytes() {
  dd if="$IMG" bs=1M skip=1 count=199 status=none | sha256sum
  dd if="$IMG" bs=1M skip=601 count=199 status=none | sha256sum
}
protected_before=$(protected_bytes)

create_partition "$IMG" "$((1000 * MIB))" "$((1200 * MIB))" fat32 MONARCH_EFI
check "create_partition succeeded (esp)" "0" "$?"
esp_num="$created_partition_number"
check "esp took the lowest free slot" "2" "$esp_num"

# Starts a MiB past the ESP, the way run_partition_decide aligns ROOT_START_B
# up from EFI_END_B + 1.
create_partition "$IMG" "$((1201 * MIB))" "$((2000 * MIB))" btrfs MONARCH_ROOT
check "create_partition succeeded (root)" "0" "$?"
root_num="$created_partition_number"
check "root took the next free slot" "3" "$root_num"

# The old prediction. If either of these ever matches again, the regression is
# back: the highest number in use was 4, so the guess would have been 5 and 6.
check "esp is not the predicted number" "not-5" "$([[ $esp_num == 5 ]] && echo 5 || echo not-5)"
check "root is not the predicted number" "not-6" "$([[ $root_num == 6 ]] && echo 6 || echo not-6)"

check "both creations tracked for rollback" "2 3" "${created_parts[*]}"
check "esp exact size" "$((200 * MIB))" "$(partition_size_bytes "$IMG" "$esp_num")"
check "root exact size" "$((799 * MIB))" "$(partition_size_bytes "$IMG" "$root_num")"
check "esp size aligned to 4096" "0" "$(( $(partition_size_bytes "$IMG" "$esp_num") % 4096 ))"
check "root size aligned to 4096" "0" "$(( $(partition_size_bytes "$IMG" "$root_num") % 4096 ))"
check "protected bytes unchanged by creation" "$protected_before" "$(protected_bytes)"

echo "==> rollback reclaims only what this run created"
rollback_created_parts "$IMG"
check "created partitions removed" "1 4" "$(partition_numbers "$IMG" | sort | tr '\n' ' ' | sed 's/ $//')"
check "rollback list cleared" "0" "${#created_parts[@]}"
check "protected bytes unchanged by rollback" "$protected_before" "$(protected_bytes)"

echo "==> numbering on a disk without holes"
rm -f "$IMG"
truncate -s 4G "$IMG"
parted --script "$IMG" mklabel gpt
mkpart_mib one ext4 1 200
mkpart_mib two ext4 201 400
created_parts=()

create_partition "$IMG" "$((1000 * MIB))" "$((1200 * MIB))" fat32 MONARCH_EFI
check "appends when there is no hole" "3" "$created_partition_number"

echo "==> a refused creation stays out of the rollback list"
created_parts=()
create_partition "$IMG" "$((100 * MIB))" "$((300 * MIB))" ext4 OVERLAP
check "overlapping creation failed" "1" "$?"
check "nothing tracked" "0" "${#created_parts[@]}"

echo "==> a created partition remains rollback-owned if validation fails"
created_parts=()
real_partition_size_bytes=$(declare -f partition_size_bytes)
partition_size_bytes() { return 1; }
create_partition "$IMG" "$((1300 * MIB))" "$((1500 * MIB))" ext4 INVALID_SIZE
check "post-create validation failed" "1" "$?"
check "the new partition is still tracked" "4" "${created_parts[*]}"
eval "$real_partition_size_bytes"
rollback_created_parts "$IMG"
check "rollback removes the failed creation" "1 2 3" \
  "$(partition_numbers "$IMG" | sort | tr '\n' ' ' | sed 's/ $//')"

echo "==> rollback ownership crosses the configurator handoff"
CONFIGURATOR="$ROOT/configs/airootfs/root/configurator"
CONFIG_WRITER="$ROOT/configs/airootfs/root/write-install-config"
grep -qF 'rollback_partitions_json="[$efi_part_num, $root_part_num]"' "$CONFIGURATOR"
check "created numbers are serialized" "0" "$?"
grep -qF 'write_protected_install_config' "$CONFIGURATOR" &&
  grep -qF '"created_partitions": $rollback_partitions_json' "$CONFIG_WRITER"
check "rollback metadata reaches the orchestrator config" "0" "$?"

if (( failures > 0 )); then
  printf '\n%d check(s) failed\n' "$failures"
  exit 1
fi
printf '\nall checks passed\n'
