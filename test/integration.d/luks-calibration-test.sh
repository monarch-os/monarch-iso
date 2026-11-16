#!/bin/bash

# Standalone: MONARCH_INTEGRATION_ISO=/path/to.iso bash test/integration.d/luks-calibration-test.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

ssh_live_root() {
  ssh -i "$SSH_KEY" -p "$SSH_PORT" -o BatchMode=yes -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 -o LogLevel=ERROR "root@127.0.0.1" "$@"
}

bootstrap_live_root_ssh() {
  local host=10.0.2.2
  [[ ${MONARCH_INTEGRATION_OFFLINE:-false} == "true" ]] && host=10.0.2.100

  mkdir -p "$RUN_DIR/www"
  cat >"$RUN_DIR/www/bootstrap-live" <<EOF
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo "$(cat "$SSH_KEY.pub")" >>/root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
EOF
  (cd "$RUN_DIR/www" && exec python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
  HTTP_PID=$!
  local attempt vt started deadline
  for attempt in 1 2 3; do
    vt=$((attempt + 2))
    started=$SECONDS
    while true; do
      press "ctrl-alt-f$vt"
      sleep 4
      ocr_screen | grep -qi 'login:' && break
      if ((SECONDS - started >= 300)); then
        capture_console failure-live-console-timeout
        return 1
      fi
    done
    press "ctrl-alt-f$vt"
    type_text root
    press ret
    sleep 2
    if ocr_screen | grep -qi password; then press ret; sleep 2; fi
    if ! wait_for_screen 'archiso [^l]*#' 30; then continue; fi
    press "ctrl-alt-f$vt"
    type_text "curl -fsS http://$host:$HTTP_PORT/bootstrap-live -o /tmp/bs && bash /tmp/bs"
    press ret
    deadline=$((SECONDS + 60))
    until ssh_live_root true 2>/dev/null; do
      vm_running || return 1
      ((SECONDS < deadline)) || break
      sleep 1
    done
    if ssh_live_root true 2>/dev/null; then
      capture_console success-live-root-ssh
      kill "$HTTP_PID"
      wait "$HTTP_PID" 2>/dev/null || true
      HTTP_PID=""
      return 0
    fi
  done
  capture_console failure-live-root-ssh
  return 1
}

[[ -f $SSH_KEY ]] || ssh-keygen -t ed25519 -N "" -q -C "monarch-integration" -f "$SSH_KEY"
qemu-img create -f qcow2 "$RUN_DIR/scratch.qcow2" 1G >/dev/null
for memory in 8192 4096; do
  cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS.4m.fd"
  ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"
  MEMORY=$memory start_vm "$RUN_DIR/scratch.qcow2" "$RUN_DIR/$memory-serial.log" \
    -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0" \
    -device ide-cd,drive=cdrom0,bootindex=2
  bootstrap_live_root_ssh
  ssh_live_root 'cat >/tmp/luks-calibration-guest.py' <"$ROOT/test/luks-calibration-guest.py"
  args=""
  ((memory != 4096)) || args="--expect-no-cache"
  if ssh_live_root "python /tmp/luks-calibration-guest.py $args" >"$RUN_DIR/$memory-calibration.json" 2>"$RUN_DIR/$memory-calibration.stderr"; then
    check "$memory MiB guest formats and unlocks through both callers" true
  else
    cat "$RUN_DIR/$memory-calibration.stderr" >&2
    check "$memory MiB guest formats and unlocks through both callers" false
  fi
  ssh_live_root 'journalctl -b -u monarch-luks-calibrate.service --no-pager' >"$RUN_DIR/$memory-calibration-unit.log"
  stop_vm
done
finish
