#!/usr/bin/env bash
#
# Live ISO entry point on tty1: set up the live VT, run the configurator
# wizard, then hand off to the Python install orchestrator. Mirrors the
# stream/env contract from the previously-working installer:
#   - stdout teed to /var/log/monarch-install.log (CSI-stripped) AND to tty
#   - stderr direct to /dev/tty so gum (which draws its TUI on stderr)
#     renders correctly
#   - CLICOLOR_FORCE/FORCE_COLOR so gum emits ANSI even with stdout piped
#   - COLUMNS/LINES so gum picks up real terminal size
set -euo pipefail

[[ $(tty) == /dev/tty1 ]] || exit 0

if [[ -f /root/monarch_iso_ref ]]; then
  export MONARCH_ISO_REF="$(cat /root/monarch_iso_ref)"
fi
export MONARCH_PATH=/usr/share/monarch
export MONARCH_INSTALL=$MONARCH_PATH/install
export MONARCH_INSTALL_LOG_FILE=/var/log/monarch-install.log
if [[ -f /usr/share/monarch-iso/install-debug ]]; then
  export MONARCH_INSTALL_DEBUG=1
fi

# Tokyo Night palette so the live VT matches the installed look.
set_tokyo_night_colors() {
  echo -en "\e]P01a1b26"; echo -en "\e]P1f7768e"; echo -en "\e]P29ece6a"
  echo -en "\e]P3e0af68"; echo -en "\e]P47aa2f7"; echo -en "\e]P5bb9af7"
  echo -en "\e]P67dcfff"; echo -en "\e]P7a9b1d6"; echo -en "\e]P8414868"
  echo -en "\e]P9f7768e"; echo -en "\e]PA9ece6a"; echo -en "\e]PBe0af68"
  echo -en "\e]PC7aa2f7"; echo -en "\e]PDbb9af7"; echo -en "\e]PE7dcfff"
  echo -en "\e]PFc0caf5"
  echo -en "\033[0m"
  clear
}
set_tokyo_night_colors

mkdir -p /var/log
touch "$MONARCH_INSTALL_LOG_FILE"

export COLUMNS=$(tput cols)
export LINES=$(tput lines)
exec > >(tee >(sed -u 's/\x1b\[[0-9;?]*[A-Za-z]//g' >>"$MONARCH_INSTALL_LOG_FILE") 2>/dev/null) 2>/dev/tty
export CLICOLOR_FORCE=1
export FORCE_COLOR=1

if [[ ${MONARCH_INSTALL_DEBUG:-} == "1" ]]; then
  echo "=== Monarch ISO debug build ==="
  [[ -f /usr/share/monarch-iso/build-info ]] && cat /usr/share/monarch-iso/build-info
  pacman -Q monarch monarch-keyring 2>/dev/null || true
  echo "================================"
fi

# Warm the page cache for the bundled packages while the user works through the
# wizard. The install reads ~3GB out of the offline mirror, and pacman consumes
# it at only ~33MB/s, so on media slower than that the install is read-bound and
# every byte cached here is a byte it never waits for. On faster media this costs
# nothing but otherwise-idle bandwidth: the medium is untouched while the user
# types, and the target disk it writes to later is a different device.
#
# Clean page cache only, so the kernel reclaims it under pressure instead of
# OOMing, and a budget so small machines never evict what was just warmed.
# Set MONARCH_NO_PREFETCH=1 to A/B the same ISO with this disabled.
warm_offline_mirror() {
  local mirror=/var/cache/monarch/mirror/offline
  local budget_kb spent_kb=0 size_kb path

  [[ ${MONARCH_NO_PREFETCH:-} == 1 ]] && return 0
  [[ -d $mirror ]] || return 0

  budget_kb=$(($(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo) / 2))
  ((budget_kb > 262144)) || return 0

  # Largest first: the install reads most of the mirror, so when the budget
  # cannot cover all of it this still front-loads the bytes that dominate.
  while read -r size_kb path; do
    ((spent_kb + size_kb > budget_kb)) && continue
    cat -- "$path" >/dev/null 2>&1 || true
    spent_kb=$((spent_kb + size_kb))
  done < <(du -k "$mirror"/*.pkg.tar.zst 2>/dev/null | sort -rn)
}

warm_offline_mirror &
warm_pid=$!
trap 'kill "$warm_pid" 2>/dev/null' EXIT

cd /root
# Autoinstall: a cidata drive carrying the configurator's own output files
# stands in for the wizard. monarch-cidata-load copies them into /root and
# everything downstream runs the ordinary path against ordinary inputs.
if /usr/local/bin/monarch-cidata-load; then
  echo "Autoinstall configuration found on cidata drive; skipping the configurator."
  export MONARCH_UI_INTERACTIVE=no
else
  cidata_status=$?
  if (( cidata_status == 2 )); then
    echo "Refusing unsupported legacy cidata; regenerate it with monarch-iso-cidata." >&2
    exit 2
  fi
  ./configurator
fi

# Deferred-provisioning installs skip the celebration/reboot prompt and reboot on
# their own — the owner completes setup at first boot. Signalled by the config's
# defer_provisioning flag (interactive) or the defer-provisioning marker (cidata).
# Parse the flag with jq (the same JSON semantics the orchestrator uses) rather
# than a line regex, so a reformatted config can't read as a direct install.
if [[ -f /root/defer-provisioning ]] ||
  [[ "$(jq -r '.monarch_install.defer_provisioning // false' /root/user_configuration.json 2>/dev/null)" == "true" ]]; then
  export MONARCH_UI_DEFER_PROVISIONING=yes
fi

# The foreground dashboard is now the sole visible install UI owner. It starts
# the actual installer as a non-interactive child, logs child output, waits for
# completion, then renders the final installed-time/reboot prompt itself.
export MONARCH_DASHBOARD_TTY="$(tty)"
rm -f /run/monarch-install/state.json
/usr/local/bin/monarch-install-dashboard \
  "$MONARCH_INSTALL_LOG_FILE" \
  /run/monarch-install/state.json \
  -- \
  /usr/local/bin/monarch-iso-install \
    --config /root/user_configuration.json \
    --creds /root/user_credentials.json \
    --full-name-file /root/user_full_name.txt \
    --email-file /root/user_email_address.txt \
    --authorized-keys-file /root/authorized_keys \
    --tailscale-authkey-file /root/tailscale_authkey \
    --defer-provisioning-file /root/defer-provisioning
