#!/bin/bash
#
# Shared harness for the integration scenarios in test/integration.d/: QEMU
# lifecycle, QMP screendump + OCR console driving, virtual keystrokes, guest
# SSH, cidata autoinstall, and the reusable base-image contract. Source this
# from a scenario; ./test/integration exports the configuration and ensures
# the base image exists before any scenario runs.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

ISO="$MONARCH_INTEGRATION_ISO"
SSH_PORT="${MONARCH_INTEGRATION_SSH_PORT:-2322}"
MEMORY="${MONARCH_INTEGRATION_MEMORY:-8192}"
INSTALL_TIMEOUT="${MONARCH_INTEGRATION_INSTALL_TIMEOUT:-2400}"
NO_PREVIEW="${MONARCH_INTEGRATION_NO_PREVIEW:-false}"
BOOT_TIMEOUT="${MONARCH_INTEGRATION_BOOT_TIMEOUT:-600}"
CPUS="${MONARCH_INTEGRATION_CPUS:-$(nproc)}"
ACCEL="${MONARCH_INTEGRATION_ACCEL:-kvm}"

GUEST_USER="monarch"
GUEST_PASSWORD="monarch"
GUEST_HOSTNAME="monarch-test"

SCENARIO="${SCENARIO:-$(basename "${0%-test.sh}")}"

OVMF_CODE="/usr/share/edk2/x64/OVMF_CODE.4m.fd"
OVMF_VARS_TEMPLATE="/usr/share/edk2/x64/OVMF_VARS.4m.fd"

BASE_DIR="$ROOT/test-runs/$(basename "$ISO" .iso)-integration"
RUN_DIR="$BASE_DIR/runs/$(date +%Y%m%d-%H%M%S)-$SCENARIO"
BASE_DISK="$BASE_DIR/base.qcow2"
BASE_OVMF="$BASE_DIR/OVMF_VARS.4m.fd"
ACTIVE_OVMF="$BASE_OVMF"
SSH_KEY="$BASE_DIR/id_ed25519"
CIDATA_IMG="$BASE_DIR/cidata.img"
HTTP_PORT=$((SSH_PORT + 1))
HTTP_PID=""

mkdir -p "$BASE_DIR" "$RUN_DIR"

QMP_SOCK=$(mktemp -u "${TMPDIR:-/tmp}/monarch-integration-qmp.XXXXXX.sock")
PIDFILE="$RUN_DIR/qemu.pid"

FAILURES=0

log() {
  printf '\033[1;35m==> %s\033[0m\n' "$1"
}

check() {
  local description="$1"
  shift

  if "$@" >/dev/null 2>&1; then
    printf 'ok - %s\n' "$description"
  else
    printf 'not ok - %s\n' "$description"
    ((FAILURES += 1))
  fi
}

finish() {
  if ((FAILURES == 0)); then
    log "$SCENARIO passed. Artifacts: $RUN_DIR"
  else
    log "$SCENARIO FAILED: $FAILURES assertion(s). Artifacts: $RUN_DIR"
    exit 1
  fi
}

base_image_ready() {
  [[ -f $BASE_DISK && -f $BASE_OVMF && -f $SSH_KEY ]]
}

# ---------------------------------------------------------------- vm control

vm_running() {
  [[ -f $PIDFILE ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

qmp() {
  printf '{"execute":"qmp_capabilities"}\n{"execute":%s}\n' "$1" |
    timeout 5 socat -t 2 - "UNIX-CONNECT:$QMP_SOCK" 2>/dev/null || true
}

screendump() {
  qmp "\"screendump\", \"arguments\": {\"filename\": \"$1\"}" >/dev/null
}

capture_console() {
  local name="$1" shot="$RUN_DIR/.capture.ppm"

  sleep 1
  screendump "$shot"
  [[ -s $shot ]] || return 0
  timeout --kill-after=5s 15s magick "$shot" "$RUN_DIR/$name.png" 2>/dev/null || true
  rm -f "$shot"
}

stop_vm() {
  vm_running || return 0

  if ! MONARCH_INTEGRATION_SSH_DEADLINE=15 ssh_guest "echo $GUEST_PASSWORD | sudo -S systemctl poweroff" >/dev/null 2>&1; then
    qmp '"system_powerdown"' >/dev/null
  fi

  local waited=0
  while vm_running && ((waited < 15)); do
    sleep 1
    ((waited += 1))
  done

  if vm_running; then
    qmp '"quit"' >/dev/null
    sleep 1
  fi

  if vm_running; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    local waited_after_term=0
    while vm_running && ((waited_after_term < 5)); do
      sleep 1
      ((waited_after_term += 1))
    done
  fi

  if vm_running; then
    kill -KILL "$(cat "$PIDFILE")" 2>/dev/null || true
  fi
}

open_screenshots() {
  local entry
  local -a screenshots=()

  while IFS= read -r -d '' entry; do
    screenshots+=("${entry#* }")
  done < <(
    find "$RUN_DIR" -type f \( -name "success-*.png" -o -name "failure-*.png" \) -printf '%T@ %p\0' |
      sort -zn
  )

  (( ${#screenshots[@]} > 0 )) || return 0

  log "Visual review: ${#screenshots[@]} screenshots in $RUN_DIR"
  [[ $NO_PREVIEW == "true" ]] && return 0

  if command -v imv >/dev/null && [[ -n ${WAYLAND_DISPLAY:-}${DISPLAY:-} ]]; then
    setsid -f imv "${screenshots[@]}" >/dev/null 2>&1
  fi
}

cleanup() {
  local status=$?

  if [[ -n $HTTP_PID ]]; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
  fi
  vm_running && log "Stopping test VM"
  stop_vm
  rm -f "$RUN_DIR/.screen.ppm" "$RUN_DIR/.screen.png"
  open_screenshots
  rmdir "$RUN_DIR" 2>/dev/null || true

  return $status
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

start_vm() {
  local disk="$1" serial="$2"
  shift 2

  local cpu=host network="user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
  [[ $ACCEL == "tcg" ]] && cpu=max
  [[ ${MONARCH_INTEGRATION_OFFLINE:-false} == "true" ]] && network+=",restrict=on"

  qemu-system-x86_64 \
    -cpu "$cpu" -machine "q35,accel=$ACCEL" \
    -smp "$CPUS" \
    -m "$MEMORY" \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$ACTIVE_OVMF" \
    -drive file="$disk",format=qcow2,if=none,id=drive0 \
    -device virtio-blk-pci,drive=drive0,bootindex=1 \
    -device virtio-vga \
    -display none \
    -usb -device usb-tablet \
    -netdev "$network" \
    -device virtio-net-pci,netdev=net0 \
    -device virtio-serial-pci \
    -chardev "file,id=install-status,path=$RUN_DIR/install-guest.log" \
    -device virtserialport,chardev=install-status,name=org.monarch.install-status \
    -qmp "unix:$QMP_SOCK,server,nowait" \
    -serial "file:$serial" \
    -pidfile "$PIDFILE" \
    -daemonize \
    "$@"
}

# Boot a throwaway overlay of the installed base. The disk gets a per-run
# overlay; the firmware vars need the same isolation or NVRAM state would
# leak between runs.
start_vm_from_base() {
  qemu-img create -f qcow2 -b "$BASE_DISK" -F qcow2 "$RUN_DIR/run.qcow2" >/dev/null
  cp "$BASE_OVMF" "$RUN_DIR/OVMF_VARS.4m.fd"
  ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"
  start_vm "$RUN_DIR/run.qcow2" "$RUN_DIR/serial.log"
}

# ------------------------------------------------------------ console driver

ocr_screen() {
  local shot="$RUN_DIR/.screen.ppm" prepped="$RUN_DIR/.screen.png"

  rm -f "$shot" "$prepped"
  screendump "$shot"
  [[ -s $shot ]] || return 0
  timeout --kill-after=5s 15s magick "$shot" -colorspace gray -negate -resize 150% "$prepped" 2>/dev/null || return 0
  timeout --kill-after=5s 15s tesseract "$prepped" - --psm 6 2>/dev/null || true
}

wait_for_screen() {
  local text="$1" timeout="$2" waited=0 slug

  until ocr_screen | grep -qi "$text"; do
    if ! vm_running; then
      echo "VM exited while waiting for screen: $text" >&2
      return 1
    fi

    if ((waited >= timeout)); then
      slug=${text,,}
      slug=${slug// /-}
      slug=${slug//[^a-z0-9-]/}
      capture_console "failure-waiting-for-$slug"
      echo "Timed out after ${timeout}s waiting for screen: $text" >&2
      return 1
    fi

    sleep 3
    ((waited += 3))
  done

  sleep 1
}

press() {
  local part json=""
  local -a parts

  IFS='-' read -ra parts <<<"$1"
  for part in "${parts[@]}"; do
    json+="{\"type\":\"qcode\",\"data\":\"$part\"},"
  done

  qmp "\"send-key\", \"arguments\": {\"keys\": [${json%,}]}" >/dev/null
}

type_text() {
  local text="$1" ch i

  for ((i = 0; i < ${#text}; i++)); do
    ch=${text:i:1}
    case "$ch" in
      [a-z0-9]) press "$ch" ;;
      [A-Z]) press "shift-${ch,,}" ;;
      " ") press spc ;;
      .) press dot ;;
      ,) press comma ;;
      -) press minus ;;
      _) press shift-minus ;;
      /) press slash ;;
      :) press shift-semicolon ;;
      "&") press shift-7 ;;
      "=") press equal ;;
      "?") press shift-slash ;;
      "!") press shift-1 ;;
      "~") press shift-grave_accent ;;
      @) press shift-2 ;;
      *) echo "type_text: unsupported character: $ch" >&2; return 1 ;;
    esac
    sleep 0.05
  done
}

# --------------------------------------------------------------------- guest

ssh_guest() {
  timeout --kill-after=5s "${MONARCH_INTEGRATION_SSH_DEADLINE:-0}s" \
    ssh -i "$SSH_KEY" -p "$SSH_PORT" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 \
    -o LogLevel=ERROR \
    "$GUEST_USER@127.0.0.1" "$@"
}

ssh_sudo() {
  ssh_guest "echo $GUEST_PASSWORD | sudo -S -p '' bash -c $(printf %q "$1")"
}

wait_for_ssh() {
  local timeout="$1" failure_name="${2:-failure-ssh-timeout}" waited=0 started=$SECONDS

  while ! MONARCH_INTEGRATION_SSH_DEADLINE=15 ssh_guest true 2>/dev/null; do
    waited=$((SECONDS - started))
    if ! vm_running; then
      echo "VM exited while waiting for SSH" >&2
      return 1
    fi

    if ((waited >= timeout)); then
      capture_console "$failure_name"
      echo "Timed out after ${timeout}s waiting for SSH" >&2
      return 1
    fi

    sleep 5
  done
}

# Authorize SSH the way a person would when the guest has no key yet (or a
# reset just scrubbed it): console login on a spare TTY, then a bootstrap
# script fetched from a throwaway host HTTP server.
bootstrap_ssh() {
  log "Authorizing SSH access via console login"

  mkdir -p "$BASE_DIR/www"
  cat >"$BASE_DIR/www/bootstrap" <<EOF
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "$(cat "$SSH_KEY.pub")" >>~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
echo "$GUEST_PASSWORD" | sudo -S ufw allow from 10.0.2.2 to any port 22 proto tcp
echo "$GUEST_PASSWORD" | sudo -S systemctl enable --now sshd.service
EOF

  (cd "$BASE_DIR/www" && exec python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
  HTTP_PID=$!

  local waited=0
  while true; do
    press ctrl-alt-f3
    sleep 4
    ocr_screen | grep -qi "login:" && break
    ((waited += 8))

    if ((waited >= 300)); then
      capture_console "failure-console-timeout"
      echo "Timed out waiting for a console login prompt" >&2
      return 1
    fi
    sleep 4
  done

  type_text "$GUEST_USER"
  press ret
  wait_for_screen "Password" 60
  # getty can paint the password prompt just before it is ready to consume
  # QMP key events; without this guard the first characters are occasionally
  # lost and the harness waits forever at an empty Password field.
  sleep 1
  type_text "$GUEST_PASSWORD"
  press ret
  # A second submit is harmless after a successful login (an empty shell
  # command) and covers the occasional dropped Return event at getty.
  sleep 1
  press ret
  # Login-shell initialization can take a few seconds on the freshly reset
  # owner account. Let it reach its prompt before injecting the command.
  sleep 15

  type_text "curl -fsS http://10.0.2.2:$HTTP_PORT/bootstrap -o /tmp/bs && bash /tmp/bs"
  press ret

  wait_for_ssh 360 "failure-bootstrap-ssh-timeout"
  capture_console "success-bootstrap-ssh"

  kill "$HTTP_PID" 2>/dev/null || true
  HTTP_PID=""
  press ctrl-alt-f1
}

build_cidata() {
  "$ROOT/bin/monarch-iso-cidata" \
    --user "$GUEST_USER" --password "$GUEST_PASSWORD" --key "$SSH_KEY.pub" \
    --disk /dev/vda --size 40G --hostname "$GUEST_HOSTNAME" \
    --timezone UTC --keyboard us --full-name "Monarch Test" \
    --email test@monarch.org --output "$CIDATA_IMG"
}

install_phase() {
  log "Installing $(basename "$ISO") unattended via cidata (headless)"

  [[ -f $SSH_KEY ]] || ssh-keygen -t ed25519 -N "" -q -C "monarch-integration" -f "$SSH_KEY"
  build_cidata

  # Build under a staging name: the finished base is promoted only after a
  # clean shutdown, so a failed install can never pass for a reusable base.
  rm -f "$BASE_DISK" "$BASE_DISK.building"
  qemu-img create -f qcow2 "$BASE_DISK.building" 40G >/dev/null
  cp "$OVMF_VARS_TEMPLATE" "$BASE_OVMF"
  ACTIVE_OVMF="$BASE_OVMF"

  start_vm "$BASE_DISK.building" "$RUN_DIR/install-serial.log" \
    -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0" \
    -device ide-cd,drive=cdrom0,bootindex=2 \
    -drive "file=$CIDATA_IMG,format=raw,if=none,id=cidata" \
    -device usb-storage,drive=cidata

  log "Waiting for the unattended install to finish (timeout ${INSTALL_TIMEOUT}s)"
  local waited=0 text progress_name started=$SECONDS next_progress=0
  while true; do
    waited=$((SECONDS - started))
    # An unattended install reboots on its own; SSH answering means the
    # installed system is up (cidata's authorized_keys enables sshd).
    if MONARCH_INTEGRATION_SSH_DEADLINE=15 ssh_guest true 2>/dev/null; then
      log "Install finished and rebooted into the installed system."
      capture_console "success-install-first-boot"
      break
    fi

    if [[ -s $RUN_DIR/install-guest.log ]] && grep -qF '[installer-state] failed:' "$RUN_DIR/install-guest.log"; then
      capture_console "failure-install-stopped"
      report_install_progress
      echo 'Install failed: guest state reports a failed phase' >&2
      return 1
    fi

    text=$(ocr_screen)

    if grep -qi "Reboot Now" <<<"$text"; then
      log "Install finished. Confirming the reboot prompt."
      capture_console "success-install-reboot"
      press ret
    fi

    if grep -qi "installation stopped" <<<"$text"; then
      capture_console "failure-install-stopped"
      printf '%s\n' "$text" | tee "$RUN_DIR/console.log"
      echo "Install failed — screenshot saved to $RUN_DIR" >&2
      return 1
    fi

    if ! vm_running; then
      echo "VM exited during install" >&2
      return 1
    fi

    if ((waited >= INSTALL_TIMEOUT)); then
      capture_console "failure-install-timeout"
      printf '%s\n' "$text" | tee "$RUN_DIR/console.log"
      echo "Timed out after ${INSTALL_TIMEOUT}s waiting for install" >&2
      return 1
    fi

    if ((waited >= next_progress)); then
      next_progress=$((waited + 120))
      printf -v progress_name 'success-install-progress-%04ds' "$waited"
      capture_console "$progress_name"
      echo "    ... installing (${waited}s)"
      report_install_progress
    fi

    sleep 10
  done

  log "Installed system is up. Saving base image."
  stop_vm
  mv "$BASE_DISK.building" "$BASE_DISK"
}

report_install_progress() {
  if [[ -s $RUN_DIR/install-guest.log ]]; then
    tail -n 24 "$RUN_DIR/install-guest.log"
  else
    echo 'Waiting for live installer telemetry; console screenshots are being saved.'
  fi
}
