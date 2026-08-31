#!/bin/bash
#
# Unit tests for the checksum sidecar monarch-iso-release writes and
# monarch-iso-upload ships. Both scripts derive everything from their own
# location and their argument, so each case runs against a throwaway sandbox
# with the real script copied in and rclone/sign/upload stubbed out.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  local description="$1"
  local detail="${2:-}"

  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# monarch-iso-release resolves its release directory from the script's own
# path, so relocating the script is what points it at the sandbox.
sandbox="$work/repo"
mkdir -p "$sandbox/bin" "$sandbox/release" "$work/stubs"
cp "$ROOT/bin/monarch-iso-release" "$sandbox/bin/"
printf 'not really an iso\n' >"$sandbox/release/monarch-2099.01.01-x86_64-dev.iso"

cat >"$work/stubs/monarch-iso-sign" <<'STUB'
#!/bin/bash
printf 'signature\n' >"$1.sig"
STUB

cat >"$work/stubs/monarch-iso-upload" <<'STUB'
#!/bin/bash
printf 'upload %s\n' "$*" >>"$TEST_LOG"
STUB

# Log one argument per field rather than "$*": the point of several cases below
# is that a path survives as a single argument, which "$*" cannot show.
cat >"$work/stubs/rclone" <<'STUB'
#!/bin/bash
printf 'rclone'
printf '|%s' "$@"
printf '\n'
[[ -n ${RCLONE_FAIL_ON:-} && $* == *"$RCLONE_FAIL_ON"* ]] && exit 1
exit 0
STUB

chmod +x "$work/stubs"/*
cp "$work/stubs/monarch-iso-sign" "$work/stubs/monarch-iso-upload" "$sandbox/bin/"

export TEST_LOG="$work/log"
: >"$TEST_LOG"

run_upload() {
  PATH="$work/stubs:$PATH" "$ROOT/bin/monarch-iso-upload" "$@" >"$work/rclone-log" 2>"$work/upload-err"
}

release_output=$(PATH="$work/stubs:$PATH" "$sandbox/bin/monarch-iso-release" --no-make 9.9.9)

release_iso="$sandbox/release/monarch-9.9.9.iso"
checksum_file="$release_iso.sha256"

[[ -f $checksum_file ]] ||
  fail "release writes a checksum beside the ISO" "missing: $checksum_file"
pass "release writes a checksum beside the ISO"

# The name in the file has to be the ISO alone. A build path in there verifies
# only on the release machine, which is the one machine that never needs it.
expected="$(sha256sum "$release_iso" | cut -d " " -f 1)  monarch-9.9.9.iso"
actual="$(cat "$checksum_file")"
[[ $actual == "$expected" ]] ||
  fail "the checksum names the ISO alone" "expected: $expected"$'\n'"actual:   $actual"
pass "the checksum names the ISO alone"

(cd "$sandbox/release" && sha256sum -c --status monarch-9.9.9.iso.sha256) ||
  fail "sha256sum -c verifies the ISO from its own directory"
pass "sha256sum -c verifies the ISO from its own directory"

grep -qF "URL:    https://iso.monarchlinux.com/monarch-9.9.9.iso" <<<"$release_output" ||
  fail "release prints the public download URL" "$release_output"
grep -qF "SHA256: $(sha256sum "$release_iso" | cut -d ' ' -f 1)" <<<"$release_output" ||
  fail "release prints the published checksum" "$release_output"
grep -qF "Local:  $release_iso" <<<"$release_output" ||
  fail "release prints the local artifact path" "$release_output"
pass "release ends with the public URL, checksum, and local path"

# The whole point of the sidecar is catching bytes that changed after release,
# so prove it fails on bytes that changed after release.
printf 'corrupted\n' >>"$release_iso"
if (cd "$sandbox/release" && sha256sum -c --status monarch-9.9.9.iso.sha256 2>/dev/null); then
  fail "sha256sum -c rejects a corrupted ISO"
fi
pass "sha256sum -c rejects a corrupted ISO"

# An unreadable ISO must stop the release rather than publish an empty digest
# beside a stale sidecar from the previous one.
stale="$sandbox/release/monarch-8.8.8.iso.sha256"
printf 'deadbeef  monarch-8.8.8.iso\n' >"$stale"
rm "$sandbox/release/monarch-2099.01.01-x86_64-dev.iso"
printf 'not really an iso\n' >"$sandbox/release/monarch-2099.01.02-x86_64-dev.iso"
cp "$sandbox/release/monarch-2099.01.02-x86_64-dev.iso" "$sandbox/release/monarch-8.8.8.iso"
chmod 000 "$sandbox/release/monarch-8.8.8.iso"

set +e
PATH="$work/stubs:$PATH" "$sandbox/bin/monarch-iso-release" --no-make 8.8.8 >/dev/null 2>&1
release_status=$?
set -e
chmod 644 "$sandbox/release/monarch-8.8.8.iso"

(( release_status != 0 )) ||
  fail "release stops when the ISO cannot be checksummed" "exit status was 0"
[[ "$(cat "$stale")" == "deadbeef  monarch-8.8.8.iso" ]] ||
  fail "a failed checksum leaves no half-written sidecar" "$(cat "$stale")"
pass "release stops when the ISO cannot be checksummed"

# Uploading: both sidecars go up with the ISO, and a missing one is skipped
# rather than handed to rclone as a path that does not exist.
export HOME="$work/home"
mkdir -p "$HOME/.config/rclone"
: >"$HOME/.config/rclone/rclone.conf"

# A space in the path is the case that tells a quoted argument from an unquoted
# one, so every upload case runs from a directory that has one.
mkdir -p "$work/release builds"
upload_iso="$work/release builds/monarch-9.9.9.iso"
printf 'not really an iso\n' >"$upload_iso"
printf 'signature\n' >"$upload_iso.sig"
printf 'checksum\n' >"$upload_iso.sha256"

run_upload "$upload_iso"

for suffix in "" ".sig" ".sha256"; do
  grep -qxF "rclone|copy|$upload_iso$suffix|Monarch:monarch/|-P" "$work/rclone-log" ||
    fail "upload ships the ISO, its signature and its checksum, path spaces intact" \
      "$(cat "$work/rclone-log")"
done
pass "upload ships the ISO, its signature and its checksum, path spaces intact"

rm "$upload_iso.sig"
set +e
run_upload "$upload_iso"
missing_sidecar_status=$?
set -e

if grep -qF ".sig" "$work/rclone-log"; then
  fail "upload skips a sidecar that is not there" "$(cat "$work/rclone-log")"
fi
grep -qF "$upload_iso.sha256" "$work/rclone-log" ||
  fail "upload still ships the checksum without a signature" "$(cat "$work/rclone-log")"
(( missing_sidecar_status != 0 )) || fail "upload fails when a required signature is missing"
pass "upload reports a missing signature while still shipping the checksum"

# A failed copy has to fail the upload even when a later copy succeeds, or a
# release reports success having published an ISO nobody can download.
printf 'signature\n' >"$upload_iso.sig"
set +e
RCLONE_FAIL_ON=".sig" run_upload "$upload_iso"
upload_status=$?
set -e
(( upload_status != 0 )) ||
  fail "a failed sidecar copy fails the upload" "$(cat "$work/rclone-log")"
grep -qF "$upload_iso.sha256" "$work/rclone-log" ||
  fail "a failed sidecar copy still attempts the rest" "$(cat "$work/rclone-log")"
pass "a failed sidecar copy fails the upload without skipping the rest"

set +e
RCLONE_FAIL_ON="monarch-9.9.9.iso" run_upload "$upload_iso"
upload_status=$?
set -e
(( upload_status != 0 )) ||
  fail "a failed ISO copy fails the upload" "$(cat "$work/rclone-log")"
pass "a failed ISO copy fails the upload"

# Publishing an ISO nobody can verify is the thing this change exists to stop,
# so the uploader says so out loud rather than exiting quietly.
rm "$upload_iso.sha256"
set +e
run_upload "$upload_iso"
missing_checksum_status=$?
set -e
(( missing_checksum_status != 0 )) || fail "upload fails when the checksum is missing"
grep -qF "Required release sidecar missing" "$work/upload-err" ||
  fail "upload reports the missing checksum" "$(cat "$work/upload-err")"
pass "upload fails when there is no checksum to publish"
