#!/bin/bash

# Checks that the configurator writes valid archinstall inputs, encrypted and
# unencrypted. The wizard itself needs a TTY, so this runs only the tail that
# generates the files: the awk below lifts it out of the configurator verbatim
# and evaluates it against fake answers. A malformed heredoc is otherwise
# invisible until an install has already wiped a disk.
#
# Run: bash test/configurator-config-test.sh

set -uo pipefail

TEST_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
CONFIGURATOR="$TEST_ROOT/configs/airootfs/root/configurator"

failures=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# jq -e prints the matched value; only its exit status matters here.
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

# From the point the answers are turned into files, through the end of the
# user_configuration.json heredoc.
generator="$work/generator.sh"
awk '
  /^# Save user full name and email address/ { emit = 1 }
  emit { print }
  /"version": "3\.0\.9"/ { closing = 1 }
  closing && /^_EOF_$/ { exit }
' "$CONFIGURATOR" >"$generator"

if [[ ! -s $generator ]] || ! grep -q 'user_configuration.json' "$generator"; then
  echo "could not lift the file generation out of $CONFIGURATOR" >&2
  exit 1
fi

# The fake answers a wizard run would have collected.
generate() {
  local outdir="$work/$1" encrypt="$2"

  mkdir -p "$outdir"
  (
    cd "$outdir" || exit 1
    DRY_RUN=true \
      full_name="Jeff Doe" \
      email_address="jeff@example.com" \
      password="hunter2" \
      password_hash='$6$fake$hash' \
      username="jeff" \
      hostname="monarch" \
      timezone="Europe/Paris" \
      keyboard="fr" \
      encrypt_installation="$encrypt" \
      bash "$generator"
  )
}

echo "an encrypted install writes valid archinstall inputs"
generate encrypted true
assert "user_configuration.json is valid JSON" jq empty "$work/encrypted/user_configuration.json"
assert "user_credentials.json is valid JSON" jq empty "$work/encrypted/user_credentials.json"
assert "the root partition is encrypted" \
  jq_e '.disk_config.disk_encryption.partitions | index("8c2c2b92-1070-455d-b76a-56263bab24aa")' \
  "$work/encrypted/user_configuration.json"
assert "the passphrase reaches the disk config" \
  jq_e '.disk_config.disk_encryption.encryption_password == "hunter2"' \
  "$work/encrypted/user_configuration.json"
assert "the passphrase reaches the credentials" \
  jq_e '.encryption_password == "hunter2"' "$work/encrypted/user_credentials.json"
assert "the user is still created" \
  jq_e '.users[0].username == "jeff"' "$work/encrypted/user_credentials.json"

echo "an unencrypted install writes valid archinstall inputs"
generate plain false
assert "user_configuration.json is valid JSON" jq empty "$work/plain/user_configuration.json"
assert "user_credentials.json is valid JSON" jq empty "$work/plain/user_credentials.json"
assert "no disk_encryption block is emitted" \
  jq_e '.disk_config | has("disk_encryption") | not' "$work/plain/user_configuration.json"
assert "no passphrase is left in the credentials" \
  jq_e 'has("encryption_password") | not' "$work/plain/user_credentials.json"
assert "the user is still created" \
  jq_e '.users[0].username == "jeff"' "$work/plain/user_credentials.json"

echo "both modes agree on everything else"
assert "same disk layout" \
  test "$(jq -S '.disk_config.device_modifications' "$work/encrypted/user_configuration.json")" \
     = "$(jq -S '.disk_config.device_modifications' "$work/plain/user_configuration.json")"
assert "same package list" \
  test "$(jq -S '.packages' "$work/encrypted/user_configuration.json")" \
     = "$(jq -S '.packages' "$work/plain/user_configuration.json")"

echo "the git identity files are written for the installer to pick up"
assert "full name" test "$(cat "$work/plain/user_full_name.txt")" = "Jeff Doe"
assert "email address" test "$(cat "$work/plain/user_email_address.txt")" = "jeff@example.com"

echo
if ((failures > 0)); then
  echo "$failures assertion(s) failed" >&2
  exit 1
fi
echo "All assertions passed"
