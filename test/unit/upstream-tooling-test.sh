#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
MAKE="$ROOT/bin/monarch-iso-make"
HARNESS="$ROOT/bin/monarch-iso-test"
STOP="$ROOT/bin/monarch-iso-test-stop"

grep -qF 'read -r -a BUILDER <<<"${BUILDER_CMD:-docker}"' "$MAKE"
grep -qF 'BUILDER=(sudo docker)' "$MAKE"
grep -qF '"${BUILDER[@]}" run' "$MAKE"

grep -qF 'VNC_DISPLAY="${MONARCH_ISO_TEST_VNC_DISPLAY:-$((SSH_PORT - 2217))}"' "$HARNESS"
grep -qF -- '-vnc "127.0.0.1:$VNC_DISPLAY"' "$HARNESS"
grep -qF 'for attempt in 1 2 3' "$HARNESS"
grep -qF 'wait_for_ssh 120 "failure-first-boot-ssh-timeout-$attempt"' "$HARNESS"
grep -qF 'ssh_guest "bash .local/share/monarch/test/all"' "$HARNESS"
grep -qF 'MONARCH_PATH=/usr/share/monarch' "$HARNESS"

[[ -x $STOP ]]
grep -qF 'is_test_vm "$pid" "$candidate"' "$STOP"
help=$($STOP --help)
grep -qF 'Usage: monarch-iso-test-stop' <<<"$help"

printf 'ok - upstream build, release, and VM harness improvements are wired in\n'
