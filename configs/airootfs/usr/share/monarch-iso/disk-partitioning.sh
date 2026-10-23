# Disk partitioning helpers, shared by the ISO configurator and its tests.
#
# The rule here is: never predict a partition number. parted fills the lowest
# free GPT slot, not "highest existing + 1", so any disk whose numbering has a
# hole — exactly what deleting a partition to free space leaves behind, which
# is what our own partition tool tells the user to do — hands back a number we
# did not choose. Everything below reads back what was actually created.
#
# Sourced, not executed. The configurator defines abort() and
# disk_abort_hook(); tests get the plain fallbacks.

# Partitions this run created, in creation order. rollback_created_parts()
# undoes exactly these and nothing else.
created_parts=()

# Set by create_partition() instead of being printed: a command substitution
# would run it in a subshell and lose the created_parts bookkeeping.
created_partition_number=""

# Compute partition device path, handling NVMe/mmcblk's pN naming.
partition_path() {
  local _disk="$1" _num="$2"
  if [[ "$_disk" == *nvme* || "$_disk" == *mmcblk* ]]; then
    echo "${_disk}p${_num}"
  else
    echo "${_disk}${_num}"
  fi
}

# Partition numbers as the on-disk GPT reports them. parted rather than lsblk
# on purpose: this is the table parted itself is about to modify, so discovery
# never depends on the kernel having re-read the partition table yet — and the
# same code works against an image file in tests, where lsblk sees nothing.
partition_numbers() {
  local table pt_type
  table=$(parted -ms "$1" unit B print 2>/dev/null) || return 1
  [[ ${table%%$'\n'*} == "BYT;" ]] || return 1
  pt_type=$(sed -n '2p' <<<"$table" | cut -d: -f6)
  [[ -n $pt_type && $pt_type != "unknown" ]] || return 1
  # Even a successful but empty/malformed response is not a partition list.
  awk -F: 'NR <= 2 { next }
    /^[1-9][0-9]*:/ { if (seen[$1]++) exit 1; print $1; next }
    NF { exit 1 }' <<<"$table"
}

partition_size_bytes() {
  local table
  table=$(parted -ms "$1" unit B print 2>/dev/null) || return 1
  printf '%s\n' "$table" |
    awk -F: -v n="$2" '$1 == n { gsub(/B/, "", $4); print $4; exit }'
}

# Read the disk itself before consulting udev's cached view. A nonempty type
# from any probe means "not blank" (including stale RAID signatures). Empty
# output is successful ONLY when parted explicitly reports an unknown table,
# blkid completed without an I/O/ambiguous-probe error, and lsblk also sees no
# table. Never turn an unreadable device into permission to run mklabel.
partition_table_type() {
  local output table pt_type parted_status=0 blkid_status=0 lsblk_status=0
  local blkid_type lsblk_type
  # Keep diagnostics: "unknown" plus an I/O error is not proof of a blank
  # disk. Fix the locale so the one expected unlabeled-disk diagnostic is
  # distinguishable from other failures without a translated-message guess.
  output=$(LC_ALL=C parted -ms "$1" print 2>&1) || parted_status=$?
  table=$(sed -n '/^BYT;$/,$p' <<<"$output")
  pt_type=$(sed -n '2p' <<<"$table" | cut -d: -f6)
  if [[ ${table%%$'\n'*} == "BYT;" && -n $pt_type && $pt_type != "unknown" ]]; then
    printf '%s\n' "$pt_type"
    return 0
  fi
  blkid_type=$(blkid -p -s PTTYPE -o value "$1" 2>/dev/null) || blkid_status=$?
  lsblk_type=$(lsblk -dno PTTYPE "$1" 2>/dev/null) || lsblk_status=$?
  if [[ -n $blkid_type || -n $lsblk_type ]]; then
    printf '%s\n' "${blkid_type:-$lsblk_type}"
    return 0
  fi
  # parted exits 1 on a genuinely unlabeled disk; blkid exits 2 when no
  # requested signature is found. Neither arbitrary failure is a blank disk.
  [[ ${table%%$'\n'*} == "BYT;" && $pt_type == "unknown" && ${table#*$'\n'} != *$'\n'* ]] &&
    [[ $output == "$table" || $output == "Error: $1: unrecognised disk label"$'\n'"$table" ]] &&
    (( parted_status <= 1 && (blkid_status == 0 || blkid_status == 2) && lsblk_status == 0 ))
}

# Fail loudly. The former version looped over sleep and returned its status,
# so a device that never appeared was indistinguishable from one that did.
wait_for_device() {
  local i
  for i in $(seq 1 10); do
    [[ -b "$1" ]] && return 0
    udevadm settle 2>/dev/null || true
    sleep 1
  done
  return 1
}

_disk_abort() {
  if declare -F disk_abort_hook >/dev/null; then
    disk_abort_hook "$1"
  elif declare -F abort >/dev/null; then
    abort "$1"
  fi
  echo "Error: $1" >&2
  exit 1
}

# Run a disk-writing command, fold its stderr into stdout, and abort on a
# non-zero exit. The fold matters: .automated_script.sh tees stdout into
# /var/log/monarch-install.log but sends stderr straight to the tty (gum draws
# its TUI there), so an unwrapped failure leaves no trace in the log the user
# uploads — and the configurator's next screen clears it off the display too.
disk_step() {
  local desc="$1"
  shift
  local output status=0
  output=$("$@" 2>&1) || status=$?
  [[ -n $output ]] && printf '%s\n' "$output"
  (( status == 0 )) && return 0
  _disk_abort "$desc failed (exit $status)"
}

# Create one partition and report the number parted actually assigned. As soon
# as the new GPT slot is identified it belongs to this run, even if a later
# size/name validation fails; the caller can then roll it back safely.
create_partition() {
  local disk="$1" start="$2" end="$3" fstype="$4" name="$5"
  local before after num removed actual want tolerance

  created_partition_number=""

  # A failed first read used to make an existing ESP look newly created.
  # Check the reads themselves, not a pipeline's final sort status.
  before=$(partition_numbers "$disk") || return 1

  parted --script "$disk" mkpart primary "$fstype" "${start}B" "${end}B" || return 1
  partprobe "$disk" 2>/dev/null || true
  udevadm settle 2>/dev/null || true

  after=$(partition_numbers "$disk") || return 1
  # A net increase of one is insufficient: two additions and a deletion are
  # not ours to claim. Require exactly one new number and no removed numbers.
  # Lexicographic order and a fixed locale are required by comm.
  before=$(LC_ALL=C sort <<<"$before") || return 1
  after=$(LC_ALL=C sort <<<"$after") || return 1
  num=$(LC_ALL=C comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after")) || return 1
  removed=$(LC_ALL=C comm -23 <(printf '%s\n' "$before") <(printf '%s\n' "$after")) || return 1
  [[ $num =~ ^[1-9][0-9]*$ && -z $removed ]] || return 1

  # The number must be genuinely new. This is the safety property that keeps a
  # numbering mistake from ever formatting a partition somebody else is using;
  # it is cheaper and more reliable than sniffing the target for signatures,
  # which would false-positive on remnants left in freed space.
  grep -qx "$num" <<<"$before" && return 1

  created_parts+=("$num")

  actual=$(partition_size_bytes "$disk" "$num") || return 1
  [[ -n $actual ]] || return 1
  want=$((end - start))
  tolerance=$((1024 * 1024))
  (( actual >= want - tolerance && actual <= want + tolerance )) || return 1

  parted --script "$disk" name "$num" "$name" || true

  created_partition_number="$num"
}

# Undo the partitions this run created, highest number first. Scoped strictly
# to created_parts: without this, a failed install leaves the user's freed
# space occupied by orphans, and the retry reports "not enough free space"
# with no way to connect that to what just happened.
rollback_created_parts() {
  local disk="$1" n
  (( ${#created_parts[@]} > 0 )) || return 0
  for n in $(printf '%s\n' "${created_parts[@]}" | sort -rn); do
    parted --script "$disk" rm "$n" >/dev/null 2>&1 || true
  done
  partprobe "$disk" 2>/dev/null || true
  created_parts=()
}
