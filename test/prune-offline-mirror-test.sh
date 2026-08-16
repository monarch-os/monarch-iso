#!/bin/bash

# Tests builder/prune-offline-mirror.sh against a fake mirror directory.
# Run: bash test/prune-offline-mirror-test.sh

set -uo pipefail

TEST_ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
PRUNER="$TEST_ROOT/builder/prune-offline-mirror.sh"

failures=0
mirror=""

setup_mirror() {
  mirror=$(mktemp -d)
  local filename
  for filename in "$@"; do
    printf 'package' >"$mirror/$filename"
  done
}

teardown_mirror() {
  [[ -n $mirror && -d $mirror ]] && rm -rf "$mirror"
  mirror=""
}

# Runs the pruner with the given filenames on stdin. Captures stdout, stderr and
# the exit status into globals so each assertion can look at one of them.
run_pruner() {
  local stderr_file
  stderr_file=$(mktemp)
  out=$(printf '%s\n' "$@" | bash "$PRUNER" "$mirror" 2>"$stderr_file")
  status=$?
  err=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# Runs the pruner with no filenames at all — printf '%s\n' with no arguments
# still emits a newline, so the empty case needs its own path.
run_pruner_empty() {
  local stderr_file
  stderr_file=$(mktemp)
  out=$(bash "$PRUNER" "$mirror" </dev/null 2>"$stderr_file")
  status=$?
  err=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

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

contains() { [[ $1 == *"$2"* ]]; }

mirror_contents() {
  find "$mirror" -maxdepth 1 -type f -printf '%f\n' | sort | tr '\n' ' '
}

echo "keeps only the exactly selected package archives"
keep="keep-2.0-1-x86_64.pkg.tar.zst"
other="other-1.0-1-any.pkg.tar.zst"
stale_version="keep-1.0-1-x86_64.pkg.tar.zst"
removed_package="removed-1.0-1-x86_64.pkg.tar.zst"
orphan_signature="interrupted-1.0-1-x86_64.pkg.tar.zst.sig"
setup_mirror \
  "$keep" "$other" "$stale_version" "$removed_package" \
  "$keep.sig" "$stale_version.sig" "$removed_package.sig" \
  "$orphan_signature" "offline.db.tar.gz"
run_pruner "$keep" "$other"
assert "exits zero" test "$status" -eq 0
assert "keeps the selection, its signature and the db" \
  test "$(mirror_contents)" = "keep-2.0-1-x86_64.pkg.tar.zst keep-2.0-1-x86_64.pkg.tar.zst.sig offline.db.tar.gz other-1.0-1-any.pkg.tar.zst "
assert "reports the superseded version" contains "$out" "$stale_version"
assert "reports the dropped package" contains "$out" "$removed_package"
teardown_mirror

echo "aborts before deleting anything when a selected package is missing"
cached="cached-1.0-1-x86_64.pkg.tar.zst"
setup_mirror "$cached"
run_pruner "missing-1.0-1-x86_64.pkg.tar.zst"
assert "exits non-zero" test "$status" -ne 0
assert "leaves the cache untouched" test -f "$mirror/$cached"
assert "says what is missing" contains "$err" "selected packages are missing"
teardown_mirror

echo "aborts before deleting anything on an empty selection"
setup_mirror "$cached"
run_pruner_empty
assert "exits non-zero" test "$status" -ne 0
assert "leaves the cache untouched" test -f "$mirror/$cached"
assert "says the selection was empty" contains "$err" "empty package selection"
teardown_mirror

echo "rejects a filename that is not a bare package archive"
setup_mirror "$cached"
run_pruner "../escape-1.0-1-x86_64.pkg.tar.zst"
assert "exits non-zero" test "$status" -ne 0
assert "leaves the cache untouched" test -f "$mirror/$cached"
assert "says the filename is invalid" contains "$err" "invalid required package filename"
teardown_mirror

echo
if ((failures > 0)); then
  echo "$failures assertion(s) failed" >&2
  exit 1
fi
echo "All assertions passed"
