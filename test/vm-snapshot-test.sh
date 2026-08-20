#!/bin/bash

# Guards monarch-vm against the paths drifting away from monarch-iso-boot again.
#
# The two agreed on /tmp until the disk moved to vm-saves/, after which `boot`
# still copied a snapshot into /tmp and then booted whatever monarch-iso-boot
# found in vm-saves — the wrong VM, with nothing said. So what is asserted here
# is mostly the handoff: the disk monarch-vm names is the disk that gets booted.
#
# Run: bash test/vm-snapshot-test.sh

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VM_SCRIPT="$ROOT/bin/monarch-vm"

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

check() {
  [[ $2 == "$3" ]] || fail "$1: expected [$3], got [$2]"
  pass "$1"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A stand-in repo: the real script, a vm-saves/ beside it, and stubs for the two
# commands it hands off to.
mkdir -p "$TMP/repo/bin" "$TMP/repo/vm-saves" "$TMP/stub"
cp "$VM_SCRIPT" "$TMP/repo/bin/monarch-vm"
VM="$TMP/repo/bin/monarch-vm"
SAVES="$TMP/repo/vm-saves"

cat >"$TMP/stub/monarch-iso-boot" <<'STUB'
#!/bin/bash
{
  echo "args: $*"
  echo "disk: ${MONARCH_VM_DISK:-<unset>}"
} >"$BOOT_LOG"
STUB

cat >"$TMP/stub/gum" <<'STUB'
#!/bin/bash
# Only what monarch-vm calls: style prints, confirm accepts, choose/input echo
# whatever the test primed. Nothing here may block.
case "$1" in
  style) shift; printf '%s\n' "$@" ;;
  confirm) [[ ${GUM_CONFIRM:-yes} == yes ]] ;;
  choose | input) printf '%s\n' "${GUM_ANSWER:-}" ;;
esac
STUB

chmod +x "$TMP/stub/monarch-iso-boot" "$TMP/stub/gum"
export PATH="$TMP/stub:$PATH"
export BOOT_LOG="$TMP/boot.log"

make_disk() {
  printf 'disk-%s' "$2" >"$SAVES/$1.qcow2"
  printf 'efi-%s' "$2" >"$SAVES/$1-OVMF_VARS.4m.fd"
}

make_disk monarch-iso-boot working
make_disk installed snapshot

booted_disk() {
  sed -n 's/^disk: //p' "$BOOT_LOG"
}

rm -f "$BOOT_LOG"
"$VM" boot installed >/dev/null || fail "boot returned non-zero on a snapshot that exists"
[[ -f $BOOT_LOG ]] || fail "boot never reached monarch-iso-boot"
check "boot hands monarch-iso-boot the snapshot it named" \
  "$(booted_disk)" "$SAVES/installed.qcow2"
check "boot asks for the disk it already has, not a fresh one" \
  "$(sed -n 's/^args: //p' "$BOOT_LOG")" "/dev/null reuse"

# The regression itself: a snapshot copied to /tmp while monarch-iso-boot read
# vm-saves/ meant `boot installed` silently started the working disk instead.
[[ $(booted_disk) != "$SAVES/monarch-iso-boot.qcow2" ]] ||
  fail "boot started the working disk instead of the snapshot"
grep -q '/tmp/' "$VM_SCRIPT" && fail "monarch-vm still stages VMs through /tmp"
pass "no /tmp staging is left in the script"

check "the snapshot is untouched by a boot" "$(cat "$SAVES/installed.qcow2")" "disk-snapshot"

rm -f "$BOOT_LOG"
"$VM" boot absent >/dev/null 2>&1 && fail "an unknown snapshot must not boot"
[[ ! -f $BOOT_LOG ]] || fail "an unknown snapshot reached monarch-iso-boot"
pass "an unknown snapshot is refused before anything boots"

mv "$SAVES/installed-OVMF_VARS.4m.fd" "$TMP/held"
rm -f "$BOOT_LOG"
"$VM" boot installed >/dev/null 2>&1 && fail "a snapshot with no EFI vars must not boot"
[[ ! -f $BOOT_LOG ]] || fail "a snapshot with no EFI vars reached monarch-iso-boot"
pass "a snapshot with no EFI variables is refused, not booted blind"
mv "$TMP/held" "$SAVES/installed-OVMF_VARS.4m.fd"

"$VM" save keep >/dev/null || fail "save returned non-zero"
check "save copies the working disk under the new name" \
  "$(cat "$SAVES/keep.qcow2")" "disk-working"
check "save takes the EFI variables with it" \
  "$(cat "$SAVES/keep-OVMF_VARS.4m.fd")" "efi-working"

MONARCH_VM_DISK="$SAVES/installed.qcow2" "$VM" save forked >/dev/null ||
  fail "save returned non-zero with MONARCH_VM_DISK set"
check "save follows MONARCH_VM_DISK, as monarch-iso-boot does" \
  "$(cat "$SAVES/forked.qcow2")" "disk-snapshot"

rm -f "$SAVES/lone-OVMF_VARS.4m.fd"
printf 'disk-lone' >"$SAVES/lone.qcow2"
MONARCH_VM_DISK="$SAVES/lone.qcow2" "$VM" save lonely >/dev/null ||
  fail "save must not fail when the source has no EFI variables yet"
pass "save succeeds when the source has no EFI variables beside it"

listed=$("$VM" list) || fail "list returned non-zero with snapshots present"
grep -q 'installed' <<<"$listed" || fail "list omits a saved snapshot"
grep -q 'monarch-iso-boot' <<<"$listed" && fail "list offers the working disk as a snapshot"
pass "list shows the snapshots and hides the working disk"

MONARCH_VM_DISK="$SAVES/installed.qcow2" "$VM" list | grep -q 'installed' &&
  fail "list still offers the disk MONARCH_VM_DISK points at"
pass "list hides whichever disk MONARCH_VM_DISK names"

rm -f "$SAVES"/*.qcow2
"$VM" boot >/dev/null 2>&1 && fail "boot must fail when there is nothing saved"
pass "boot with no snapshots fails instead of picking something"
