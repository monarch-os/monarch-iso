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
grep -qF -- '-device virtio-vga-gl' "$HARNESS"
grep -qF -- '-display egl-headless,rendernode=/dev/dri/renderD128' "$HARNESS"
grep -qF 'for attempt in 1 2 3' "$HARNESS"
grep -qF 'wait_for_ssh 120 "failure-first-boot-ssh-timeout-$attempt"' "$HARNESS"
grep -qF 'ssh_guest "bash .local/share/monarch/test/all"' "$HARNESS"
grep -qF 'MONARCH_PATH=/usr/share/monarch' "$HARNESS"
grep -qF 'wait_for_screen "Cybersecurity" 300' "$HARNESS"
grep -qF 'niri.wayland-*.$pid.sock' "$HARNESS"
grep -qF -- '--acceptance-autologin) ACCEPTANCE_AUTOLOGIN=true' "$HARNESS"
grep -qF 'press ret # English (US) is the first layout' "$HARNESS"
grep -qF 'pgrep -u "$(id -u)" -x niri' "$HARNESS"
grep -qF 'start_vm "$RUN_DIR/run.qcow2" "$RUN_DIR/serial.log" || return 1' "$HARNESS"
[[ $(grep -c 'wait_for_screen "software profile" 60' "$HARNESS") == 2 ]]
! grep -qF 'wait_for_screen "Opinionated"' "$HARNESS"
! grep -qE 'hyprctl|skip-shortcuts|SKIP_SHORTCUTS' "$HARNESS"

[[ -x $STOP ]]
grep -qF 'is_test_vm "$pid" "$candidate"' "$STOP"
help=$($STOP --help)
grep -qF 'Usage: monarch-iso-test-stop' <<<"$help"

printf 'ok - upstream build, release, and VM harness improvements are wired in\n'
