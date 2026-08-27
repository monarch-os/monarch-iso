#!/bin/bash

# Covers the archinstall inputs an install is driven by: the shared generator
# both front-ends write them with, and the guards bin/monarch-iso-cidata puts in
# front of it. A malformed heredoc here is invisible until an install has
# already wiped a disk.
#
# Run: bash test/install-config-test.sh

set -uo pipefail

TEST_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
GENERATOR="$TEST_ROOT/configs/airootfs/root/write-install-config"
HELPER="$TEST_ROOT/bin/monarch-iso-cidata"

failures=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

jq_e() { jq -e "$@" >/dev/null; }

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

# The answers a wizard run would have collected, for a 30G guest disk.
generate() {
  local outdir="$work/$1" encrypt="$2"
  mkdir -p "$outdir"
  (
    cd "$outdir" || exit 1
    disk=/dev/vda
    disk_size=$((30 * 1024 * 1024 * 1024))
    username=jeff
    password=hunter2
    password_hash='$6$fake$hash'
    full_name="Jeff Doe"
    email_address=jeff@example.com
    hostname=monarch
    timezone=Europe/Paris
    keyboard=fr
    encrypt_installation="$encrypt"
    source "$GENERATOR"
  )
}

echo "an encrypted install writes valid archinstall inputs"
generate encrypted true
assert "user_configuration.json is valid JSON" jq empty "$work/encrypted/user_configuration.json"
assert "user_credentials.json is valid JSON" jq empty "$work/encrypted/user_credentials.json"
assert "the root partition is encrypted" \
  jq_e '.disk_config.disk_encryption.partitions | index("8c2c2b92-1070-455d-b76a-56263bab24aa")' \
  "$work/encrypted/user_configuration.json"
assert "the passphrase reaches the credentials" \
  jq_e '.encryption_password == "hunter2"' "$work/encrypted/user_credentials.json"

echo "an unencrypted install writes valid archinstall inputs"
generate plain false
assert "user_configuration.json is valid JSON" jq empty "$work/plain/user_configuration.json"
assert "no disk_encryption block is emitted" \
  jq_e '.disk_config | has("disk_encryption") | not' "$work/plain/user_configuration.json"
assert "no passphrase is left in the credentials" \
  jq_e 'has("encryption_password") | not' "$work/plain/user_credentials.json"
assert "the user is still created" \
  jq_e '.users[0].username == "jeff"' "$work/plain/user_credentials.json"
assert "the git identity is written for the installer to pick up" \
  test "$(cat "$work/plain/user_full_name.txt")" = "Jeff Doe"

# `iso` would copy the live medium's networkd files into the target and enable
# them against NetworkManager, which owns the links.
assert "archinstall is asked for NetworkManager, not the ISO's own config" \
  jq_e '.network_config.type == "nm"' "$work/plain/user_configuration.json"

echo "the partitions fit the disk they were sized for"
read -r start size < <(jq -r '.disk_config.device_modifications[0].partitions[1]
  | "\(.start.value) \(.size.value)"' "$work/plain/user_configuration.json")
assert "root ends within the 30G disk, leaving the GPT backup reserve" \
  test $((start + size)) -le $((30 * 1024 * 1024 * 1024 - 1024 * 1024))
assert "root fills what is left of it" \
  test $((start + size)) -gt $((28 * 1024 * 1024 * 1024))

# --- bin/monarch-iso-cidata -------------------------------------------------

run_helper() {
  out=$("$HELPER" "$@" 2>&1)
  status=$?
}

echo "the helper refuses what would produce an unusable drive"
run_helper --key /dev/null
assert "no --user is refused" test "$status" -ne 0
assert "and says so" grep -q -- "--user or --defer-provisioning is required" <<<"$out"

run_helper --user "Not A User" --key /dev/null
assert "an invalid username is refused" test "$status" -ne 0

printf '# only a comment\n\n' >"$work/empty.pub"
run_helper --user jeff --key "$work/empty.pub"
assert "a key file with no usable key is refused" test "$status" -ne 0
assert "and says which file" grep -q "$work/empty.pub" <<<"$out"

run_helper --user jeff --key "$work/missing.pub"
assert "a missing key file is refused" test "$status" -ne 0

echo 'ssh-ed25519 AAAA jeff@host' >"$work/id.pub"
run_helper --user jeff --key "$work/id.pub" --size 30Q
assert "an unreadable size is refused" test "$status" -ne 0

echo "the helper builds a drive the loader will recognise"
run_helper --user jeff --key "$work/id.pub" --size 24G --hostname box \
  --timezone UTC --keyboard us -o "$work/cidata.iso"
assert "it succeeds" test "$status" -eq 0
assert "the volume is labelled cidata" \
  bash -c "xorriso -indev '$work/cidata.iso' -pvd_info 2>/dev/null | grep -qi \"Volume Id *: cidata\""
mkdir -p "$work/extracted"
xorriso -osirrox on -indev "$work/cidata.iso" -extract / "$work/extracted" >/dev/null 2>&1
for file in user_configuration.json user_credentials.json authorized_keys; do
  assert "the drive carries $file" test -f "$work/extracted/$file"
done
assert "the flags reached the configuration" \
  jq_e '.hostname == "box" and .timezone == "UTC" and .locale_config.kb_layout == "us"' \
  "$work/extracted/user_configuration.json"
assert "the size flag reached the partition table" \
  jq_e '[.disk_config.device_modifications[0].partitions[].size.value] | add < (24 * 1024 * 1024 * 1024)' \
  "$work/extracted/user_configuration.json"

echo "the helper builds a userless deferred-provisioning drive"
rm -rf "$work/extracted"
mkdir -p "$work/extracted"
run_helper --defer-provisioning --size 24G --hostname handoff \
  --timezone UTC --keyboard us --encrypt -o "$work/deferred.iso"
assert "deferred provisioning succeeds without a user or SSH key" test "$status" -eq 0
xorriso -osirrox on -indev "$work/deferred.iso" -extract / "$work/extracted" >/dev/null 2>&1
assert "the marker replaces credentials" test -f "$work/extracted/defer-provisioning"
assert "no deployment credentials are shipped" test ! -e "$work/extracted/user_credentials.json"
assert "no SSH key is required" test ! -e "$work/extracted/authorized_keys"
assert "the Monarch contract defers owner creation" \
  jq_e '.monarch_install.defer_provisioning == true' "$work/extracted/user_configuration.json"
assert "encrypted handoff carries no deployment passphrase" \
  jq_e '.disk_config.disk_encryption | has("encryption_password") | not' \
  "$work/extracted/user_configuration.json"

run_helper --user jeff --defer-provisioning --key "$work/id.pub"
assert "a user cannot also be deferred" test "$status" -ne 0

echo
if ((failures > 0)); then
  echo "$failures assertion(s) failed" >&2
  exit 1
fi
echo "All assertions passed"
