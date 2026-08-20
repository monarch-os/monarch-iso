#!/bin/bash

# Tests monarch-cidata-load against a throwaway sandbox, with mount, umount and
# udevadm stubbed: "mounting" copies the fake drive into the mountpoint, and each
# stub logs its invocation so a case can assert what was (not) called.
#
# Run: bash test/cidata-load-test.sh

set -uo pipefail

TEST_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
CIDATA_LOAD="$TEST_ROOT/configs/airootfs/usr/local/bin/monarch-cidata-load"

failures=0
work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT

stub_dir="$work/stubs"
mkdir -p "$stub_dir"

cat >"$stub_dir/udevadm" <<'STUB'
#!/bin/bash
printf 'udevadm %s\n' "$*" >>"$TEST_LOG"
STUB

cat >"$stub_dir/mount" <<'STUB'
#!/bin/bash
printf 'mount %s\n' "$*" >>"$TEST_LOG"
[[ ${MOUNT_FAIL:-} == 1 ]] && exit 32
device=$3 mountpoint=$4
cp -a "$(readlink -f "$device")"/. "$mountpoint"/
STUB

cat >"$stub_dir/umount" <<'STUB'
#!/bin/bash
printf 'umount %s\n' "$*" >>"$TEST_LOG"
STUB

chmod +x "$stub_dir"/*

assert() {
  local description="$1"
  shift
  if "$@"; then
    echo "  ok: $description"
  else
    echo "  FAIL: $description" >&2
    ((failures++))
  fi
}

new_sandbox() {
  sandbox=$(mktemp -d "$work/sandbox.XXXXXX")
  mkdir -p "$sandbox/dev/disk/by-label" "$sandbox/root" "$sandbox/media"
  export TEST_LOG="$sandbox/calls.log"
  : >"$TEST_LOG"
}

attach_drive() {
  ln -s "$sandbox/media" "$sandbox/dev/disk/by-label/$1"
}

# Captures the exit status so a case can assert on it without set -e aborting.
# Invoked through bash like every other script here: the executable bit is set
# by configs/profiledef.sh when the ISO is assembled, not in the checkout.
run_load() {
  PATH="$stub_dir:$PATH" bash "$CIDATA_LOAD" "$sandbox" 2>/dev/null
  status=$?
}

write_required_pair() {
  echo '{"disk_config": {}}' >"$sandbox/media/user_configuration.json"
  echo '{"users": [{"username": "jeff"}]}' >"$sandbox/media/user_credentials.json"
}

logged() { grep -q "$2" "$1"; }
not_logged() { ! grep -q "$2" "$1"; }

echo "no cidata drive falls back to the wizard"
new_sandbox
run_load
assert "exits non-zero" test "$status" -ne 0
assert "mounts nothing" not_logged "$TEST_LOG" '^mount '
assert "settles udev before concluding there is no drive" logged "$TEST_LOG" '^udevadm settle$'

echo "a drive with the full file set loads"
new_sandbox
attach_drive cidata
write_required_pair
echo "Jeff" >"$sandbox/media/user_full_name.txt"
echo "jeff@example.com" >"$sandbox/media/user_email_address.txt"
echo 'ssh-ed25519 AAAA jeff@host' >"$sandbox/media/authorized_keys"
run_load
assert "exits zero" test "$status" -eq 0
for file in user_configuration.json user_credentials.json user_full_name.txt user_email_address.txt authorized_keys; do
  assert "copies $file" test -f "$sandbox/root/$file"
done
assert "unmounts the drive" logged "$TEST_LOG" '^umount '

echo "the uppercase label variant some tools produce works too"
new_sandbox
attach_drive CIDATA
write_required_pair
run_load
assert "exits zero" test "$status" -eq 0
assert "copies the configuration" test -f "$sandbox/root/user_configuration.json"

echo "the required pair alone is a valid autoinstall drive"
new_sandbox
attach_drive cidata
write_required_pair
echo 'ssh-ed25519 AAAA jeff@host' >"$sandbox/media/authorized_keys"
run_load
assert "exits zero" test "$status" -eq 0
assert "copies the optional file that is present" test -f "$sandbox/root/authorized_keys"
assert "copies no optional file that is absent" test ! -e "$sandbox/root/user_full_name.txt"

echo "half the required pair is not an autoinstall drive"
new_sandbox
attach_drive cidata
echo '{"disk_config": {}}' >"$sandbox/media/user_configuration.json"
run_load
assert "exits non-zero" test "$status" -ne 0
assert "copies nothing" test ! -e "$sandbox/root/user_configuration.json"
assert "still unmounts" logged "$TEST_LOG" '^umount '

echo "an empty drive labeled cidata is not an autoinstall drive either"
new_sandbox
attach_drive cidata
run_load
assert "exits non-zero" test "$status" -ne 0
assert "still unmounts" logged "$TEST_LOG" '^umount '

echo "stale inputs from a previous load are cleared before the current drive is copied"
new_sandbox
attach_drive cidata
write_required_pair
echo 'old-keys' >"$sandbox/root/authorized_keys"
echo "Someone Else" >"$sandbox/root/user_full_name.txt"
run_load
assert "exits zero" test "$status" -eq 0
assert "clears an authorized_keys the current drive does not carry" test ! -e "$sandbox/root/authorized_keys"
assert "clears a full name the current drive does not carry" test ! -e "$sandbox/root/user_full_name.txt"

echo "stale inputs are cleared even when falling back to the wizard"
new_sandbox
attach_drive cidata
echo '{"disk_config": {}}' >"$sandbox/media/user_configuration.json" # half a pair
echo 'old-keys' >"$sandbox/root/authorized_keys"
run_load
assert "exits non-zero" test "$status" -ne 0
assert "clears the stale authorized_keys" test ! -e "$sandbox/root/authorized_keys"

echo "a drive that will not mount falls back rather than failing the boot"
new_sandbox
attach_drive cidata
write_required_pair
MOUNT_FAIL=1 run_load
assert "exits non-zero" test "$status" -ne 0
assert "has nothing to unmount" not_logged "$TEST_LOG" '^umount '

echo "a copy failure does not report a loaded drive"
new_sandbox
attach_drive cidata
write_required_pair
chmod 555 "$sandbox/root"
run_load
assert "exits non-zero" test "$status" -ne 0
assert "still unmounts" logged "$TEST_LOG" '^umount '
chmod 755 "$sandbox/root"

echo "a partial copy cleans up what it copied"
new_sandbox
attach_drive cidata
write_required_pair
echo 'ssh-ed25519 AAAA jeff@host' >"$sandbox/media/authorized_keys"
mkdir "$sandbox/root/user_credentials.json" # cp cannot overwrite a directory
run_load
assert "exits non-zero" test "$status" -ne 0
assert "removes the configuration it had already copied" test ! -e "$sandbox/root/user_configuration.json"
assert "leaves no authorized_keys behind" test ! -e "$sandbox/root/authorized_keys"

echo
if ((failures > 0)); then
  echo "$failures assertion(s) failed" >&2
  exit 1
fi
echo "All assertions passed"
