#!/bin/bash

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

(
  export MONARCH_INTEGRATION_ISO="$tmp/progress-candidate.iso"
  source "$root/test/integration.d/base-test.sh"
  trap - EXIT
  rmdir "$RUN_DIR" "$BASE_DIR/runs" "$BASE_DIR" 2>/dev/null || true
  BASE_DIR="$tmp/base"
  RUN_DIR="$tmp/run"
  mkdir -p "$BASE_DIR" "$RUN_DIR"
  BASE_DISK="$BASE_DIR/base.qcow2"
  BASE_OVMF="$BASE_DIR/OVMF.fd"
  SSH_KEY="$BASE_DIR/key"
  OVMF_VARS_TEMPLATE="$tmp/vars.fd"
  touch "$SSH_KEY" "$OVMF_VARS_TEMPLATE"

  build_cidata() { :; }
  qemu-img() { :; }
  start_vm() { touch "$1"; }
  stop_vm() { :; }
  vm_running() { return 0; }
  capture_console() { :; }
  ocr_screen() { echo 'Installing base system'; }
  probes=0
  ssh_guest() {
    probes=$((probes + 1))
    ((probes >= 4))
  }
  sleeps=0
  sleep() {
    sleeps=$((sleeps + 1))
    case "$sleeps" in
      1) SECONDS=119 ;;
      2) SECONDS=121 ;;
      *) SECONDS=122 ;;
    esac
  }
  SECONDS=0
  install_phase >"$tmp/progress.log"

  probes=0
  ssh_guest() {
    probes=$((probes + 1))
    ((probes >= 3))
  }
  sleep() { SECONDS=121; }
  SECONDS=0
  if wait_for_ssh 120 >"$tmp/ssh-wait.log" 2>&1; then
    echo 'not ok - SSH readiness ignores time spent probing the guest'
    exit 1
  fi
  grep -q 'Timed out after 120s' "$tmp/ssh-wait.log"
  echo 'ok - SSH readiness respects the wall-clock deadline'
)

if ! grep -q 'installing (121s)' "$tmp/progress.log"; then
  echo 'not ok - progress is reported when a poll skips the exact interval'
  cat "$tmp/progress.log"
  exit 1
fi
grep -q 'Installing base system' "$tmp/progress.log"
echo 'ok - progress reports elapsed time and guest console even when a poll skips the interval'

mkdir -p "$tmp/bin"
cat >"$tmp/bin/ssh" <<'EOF'
#!/bin/bash
sleep 10
EOF
chmod +x "$tmp/bin/ssh"

if ! PATH="$tmp/bin:$PATH" MONARCH_INTEGRATION_ISO="$tmp/ssh-candidate.iso" \
  MONARCH_INTEGRATION_SSH_DEADLINE=1 timeout --kill-after=1s 3s bash -c '
    source "$1"
    trap - EXIT
    rmdir "$RUN_DIR" "$BASE_DIR/runs" "$BASE_DIR" 2>/dev/null || true
    if ssh_guest true; then
      exit 1
    else
      [[ $? == 124 ]]
    fi
  ' _ "$root/test/integration.d/base-test.sh"; then
  echo 'not ok - the SSH deadline terminates a connected but stalled probe'
  exit 1
fi
echo 'ok - the SSH deadline terminates a connected but stalled probe'
