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
  stop_vm() {
    [[ -s $BASE_DIR/monarch-install-timing.json && -s $BASE_DIR/monarch-install.log && -s $BASE_DIR/first-boot-systemd-analyze.txt ]] || {
      echo 'not ok - install and first-boot diagnostics must be saved before shutdown' >&2
      return 1
    }
  }
  vm_running() { return 0; }
  capture_console() { echo "$1" >>"$tmp/install-captures"; }
  ocr_screen() { echo 'Installing base system'; }
  probes=0
  ssh_guest() {
    if [[ $1 != "true" ]]; then
      echo 'Startup finished in 10s'
      return
    fi
    probes=$((probes + 1))
    ((probes >= 4))
  }
  ssh_sudo() {
    case "$1" in
      *monarch-install-timing.json*) echo '{"phases":[]}' ;;
      *monarch-install.log*) echo 'Installation complete.' ;;
      *) return 1 ;;
    esac
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
  grep -qF 'Installation complete.' "$BASE_DIR/monarch-install.log"
  echo 'ok - install timings, log and first-boot timings survive a later boot failure'

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

  probes=0
  capture_console() { echo "$1" >>"$tmp/captures"; }
  ssh_guest() {
    probes=$((probes + 1))
    ((probes >= 4))
  }
  sleep() { SECONDS=$((SECONDS + 35)); }
  SECONDS=0
  wait_for_ssh 120 >"$tmp/ssh-progress.log"
  grep -qF 'waiting-ssh-0035s' "$tmp/captures"
  grep -qF 'waiting for SSH (70s)' "$tmp/ssh-progress.log"
  echo 'ok - a slow boot reports SSH progress and saves console screenshots'

  ocr_screen() {
    printf 'Monarch installation stopped\nTypeError: Installer.sanity_check rejected offline\n'
  }
  ssh_guest() { return 1; }
  sleep() { SECONDS=3000; }
  SECONDS=0
  if install_phase >"$tmp/failure.log" 2>&1; then
    echo 'not ok - a stopped installer must fail validation'
    exit 1
  fi
  grep -qF 'Install failed' "$tmp/failure.log"
  grep -qF 'sanity_check rejected offline' "$RUN_DIR/console.log"
  echo 'ok - a stopped installer aborts validation and preserves console diagnostics'

  ocr_screen() { echo 'Installing base system'; }
  sleep() { SECONDS=121; }
  INSTALL_TIMEOUT=120
  SECONDS=0
  if install_phase >"$tmp/install-timeout.log" 2>&1; then
    echo 'not ok - an installation past its deadline was accepted'
    exit 1
  fi
  grep -qF 'Timed out after 120s waiting for install' "$tmp/install-timeout.log"
  grep -qF 'Installing base system' "$RUN_DIR/console.log"
  echo 'ok - a stalled installation fails at its deadline and preserves console diagnostics'

  ocr_screen() {
    echo 'ERROR: Failed to open encryption mapping: The device PARTUUID=test is not a LUKS volume and the crypto= parameter was not specified.'
  }
  INSTALL_TIMEOUT=1
  SECONDS=0
  if install_phase >"$tmp/boot-failure.log" 2>&1; then
    echo 'not ok - a failed root unlock must fail validation'
    exit 1
  fi
  grep -qF 'Boot failed: root encryption mapping could not be opened' "$tmp/boot-failure.log"
  grep -qF 'not a LUKS volume' "$RUN_DIR/console.log"
  echo 'ok - an invalid LUKS boot configuration aborts without waiting for the install deadline'
)

if ! grep -q 'installing (119s)' "$tmp/progress.log"; then
  echo 'not ok - progress is reported when a poll skips the exact interval'
  cat "$tmp/progress.log"
  exit 1
fi
grep -qF 'success-install-progress-0121s' "$tmp/install-captures"
echo 'ok - progress reports elapsed time and saves screenshots even when a poll skips the interval'

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
      (( $? == 124 ))
    fi
  ' _ "$root/test/integration.d/base-test.sh"; then
  echo 'not ok - the SSH deadline terminates a connected but stalled probe'
  exit 1
fi
echo 'ok - the SSH deadline terminates a connected but stalled probe'
