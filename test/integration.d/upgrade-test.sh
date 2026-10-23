#!/bin/bash
# integration:opt-in
# Run explicitly: ./test/integration release/monarch.iso upgrade --reuse-base --no-preview
# Needs Internet and an accessible EGL render node (default /dev/dri/renderD128).
# Upgrades only a throwaway overlay. No runtime sync or logging bypass: exercise
# the installed monarch-update -y, including its real script(1) pseudo-terminal.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

[[ ${MONARCH_INTEGRATION_OFFLINE:-false} != "true" ]] || {
  echo "The upgrade scenario needs network access; omit --offline." >&2
  exit 1
}
UPDATE_TIMEOUT=${MONARCH_INTEGRATION_UPDATE_TIMEOUT:-1800}
[[ $UPDATE_TIMEOUT =~ ^[1-9][0-9]*$ ]] || { echo "Invalid update timeout" >&2; exit 1; }
export MONARCH_INTEGRATION_RENDER_NODE=${MONARCH_INTEGRATION_RENDER_NODE:-/dev/dri/renderD128}
[[ -r $MONARCH_INTEGRATION_RENDER_NODE && -w $MONARCH_INTEGRATION_RENDER_NODE ]] || {
  echo "The upgrade desktop check needs an accessible EGL render node." >&2
  exit 1
}
base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }

session_environment='
  export XDG_RUNTIME_DIR=/run/user/$(id -u)
  export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
  export WAYLAND_DISPLAY=$(systemctl --user show-environment | sed -n "s/^WAYLAND_DISPLAY=//p" | head -n1)
  export NIRI_SOCKET=$(monarch-hw-niri-socket 2>/dev/null)'

desktop_ready() {
  local command="
    while true; do
      $session_environment
      "'
      if [[ -n $NIRI_SOCKET && -n $WAYLAND_DISPLAY ]] &&
        niri msg --json outputs | jq -e "length > 0" &&
        noctalia msg status && noctalia config validate; then
        exit 0
      fi
      sleep 2
    done'
  MONARCH_INTEGRATION_SSH_DEADLINE=150 ssh_guest "timeout --kill-after=5s 120s bash -c $(printf %q "$command")" \
    >"$RUN_DIR/desktop-$1.log" 2>&1
}

desktop_shot() {
  # egl-headless has no QMP screendump surface. Ask the real compositor to
  # capture its screen instead, rather than silently losing before/after shots.
  local directory command
  directory=$(ssh_guest 'mktemp -d /tmp/monarch-upgrade-shot.XXXXXX')
  command="$session_environment
    niri msg action screenshot-screen --path $(printf %q "$directory/screen.png")
    for ((i=0; i<50; i++)); do
      test -s $(printf %q "$directory/screen.png") && exit 0
      sleep 0.1
    done
    exit 1"
  MONARCH_INTEGRATION_SSH_DEADLINE=15 ssh_guest "$command" >"$RUN_DIR/screenshot-$1.log" 2>&1
  ssh_guest "cat $(printf %q "$directory/screen.png")" >"$RUN_DIR/success-upgrade-$1.png"
  ssh_guest "rm -rf $(printf %q "$directory")"
}

diagnostics() {
  capture_console "failure-upgrade-$1"
  MONARCH_INTEGRATION_SSH_DEADLINE=15 ssh_sudo 'journalctl -b --no-pager' >"$RUN_DIR/failure-journal.log" 2>&1 || true
}

start_vm_from_base
wait_for_ssh "$BOOT_TIMEOUT"
boot_id_pattern='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
before_boot=$(ssh_guest 'cat /proc/sys/kernel/random/boot_id')
[[ $before_boot =~ $boot_id_pattern ]] || { echo "Could not read boot ID" >&2; exit 1; }
ssh_guest 'pacman -Q' >"$RUN_DIR/packages-before.txt"

# Test-only autologin and authorization live only in the throwaway overlay.
# -y does not supply a sudo password: avoid confusing authentication with the
# reboot-confirmation regression, even when the updater invalidates its cache.
ssh_sudo "mkdir -p /etc/sddm.conf.d
  printf '%s\n' '[Autologin]' 'User=$GUEST_USER' 'Session=niri.desktop' 'Relogin=false' > /etc/sddm.conf.d/98-monarch-upgrade-test.conf
  printf '%s\n' 'Defaults:$GUEST_USER verifypw=never' '$GUEST_USER ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-monarch-upgrade-test
  chmod 0440 /etc/sudoers.d/99-monarch-upgrade-test
  visudo -cf /etc/sudoers.d/99-monarch-upgrade-test && systemctl restart sddm"
if ! desktop_ready before; then
  diagnostics desktop-before
  echo "The initial Niri/Noctalia session did not become ready" >&2
  exit 1
fi
desktop_shot before

# Exercise reboot deferral even if this repository transaction has no kernel
# upgrade. Use this boot's identity so stale-marker cleanup cannot erase the
# fixture before the updater reaches its confirmation stage.
ssh_guest 'mkdir -p ~/.local/state/monarch; cat /proc/sys/kernel/random/boot_id > ~/.local/state/monarch/reboot-required'

log "Running the installed monarch-update -y (deadline ${UPDATE_TIMEOUT}s)"
update_status=0
MONARCH_INTEGRATION_SSH_DEADLINE=$((UPDATE_TIMEOUT + 30)) \
  ssh_guest "timeout --kill-after=15s ${UPDATE_TIMEOUT}s env -u MONARCH_UPDATE_LOGGED MONARCH_PATH=/usr/share/monarch monarch-update -y </dev/null" \
  >"$RUN_DIR/update.log" 2>&1 || update_status=$?
printf '%s\n' "$update_status" >"$RUN_DIR/update-status.txt"
if ((update_status != 0)); then
  diagnostics update
  echo "Unattended update failed or timed out (status $update_status); see update.log" >&2
  exit 1
fi
after_update_boot=$(ssh_guest 'cat /proc/sys/kernel/random/boot_id')
check "The updater did not reboot the guest" test "$before_boot" = "$after_update_boot"
check "The unattended updater retains the pending reboot" ssh_guest 'test -f ~/.local/state/monarch/reboot-required'
((FAILURES == 0)) || { diagnostics unexpected-reboot; finish; exit 1; }
ssh_guest 'pacman -Q' >"$RUN_DIR/packages-updated.txt"
if cmp -s "$RUN_DIR/packages-before.txt" "$RUN_DIR/packages-updated.txt"; then
  echo "No packages changed: this base did not exercise a package upgrade." >&2
  exit 1
fi
diff -u "$RUN_DIR/packages-before.txt" "$RUN_DIR/packages-updated.txt" >"$RUN_DIR/packages.diff" || true
ssh_sudo 'rm -f /etc/sudoers.d/99-monarch-upgrade-test'

log "Rebooting the upgraded guest without console input"
ssh_sudo 'systemctl reboot' >"$RUN_DIR/reboot.log" 2>&1 || true
started=$SECONDS
while true; do
  after_boot=$(MONARCH_INTEGRATION_SSH_DEADLINE=15 ssh_guest 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)
  if [[ $after_boot =~ $boot_id_pattern && $after_boot != "$before_boot" ]]; then break; fi
  if ! vm_running || ((SECONDS - started >= BOOT_TIMEOUT)); then
    diagnostics reboot
    ocr_screen >"$RUN_DIR/console.log"
    echo "The upgraded guest did not reboot unattended" >&2
    exit 1
  fi
  sleep 2
done
printf '%s\n' "$before_boot" "$after_boot" >"$RUN_DIR/boot-ids.txt"
check "The upgraded system boots through UEFI" ssh_guest 'test -d /sys/firmware/efi'
check "The upgraded system reaches running state" ssh_guest 'timeout 120 systemctl is-system-running --wait'
ssh_guest 'systemctl --failed --no-legend --plain' >"$RUN_DIR/failed-units.txt"
check "No system units failed after the upgrade" test ! -s "$RUN_DIR/failed-units.txt"
if ! desktop_ready after; then
  diagnostics desktop-after
  echo "The upgraded Niri/Noctalia session did not become ready" >&2
  exit 1
fi
ssh_sudo 'journalctl -b --no-pager' >"$RUN_DIR/journal.log"
ssh_guest 'pacman -Q' >"$RUN_DIR/packages-after.txt"
desktop_shot after
stop_vm
finish
