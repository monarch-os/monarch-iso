#!/usr/bin/env bash
set -euo pipefail

# Set by an autoinstall drive. Read in two places, because openssh must be
# pulled before the Monarch installer and enabled after it.
AUTHORIZED_KEYS=/root/authorized_keys

# Set when an autoinstall drive stood in for the wizard. Passed into the chroot
# so the Monarch installer skips the prompts nobody is there to answer — they
# read the TTY and would hang the install forever.
MONARCH_UNATTENDED=""

use_monarch_helpers() {
  export MONARCH_PATH="/root/monarch"
  export MONARCH_INSTALL="/root/monarch/install"
  export MONARCH_INSTALL_LOG_FILE="/var/log/monarch-install.log"
  source /root/monarch/install/helpers/all.sh
}

run_configurator() {
  set_tokyo_night_colors

  # An autoinstall drive stands in for the wizard; everything downstream then
  # runs the ordinary path against ordinary inputs.
  if /usr/local/bin/monarch-cidata-load; then
    echo "Autoinstall configuration found on the cidata drive; skipping the configurator."
    MONARCH_UNATTENDED=1
  else
    ./configurator
  fi

  # Caught here rather than mid-chroot, where nothing would point back at the
  # drive that caused it.
  MONARCH_USER="$(jq -r '.users[0].username // empty' user_credentials.json)"
  if [[ -z $MONARCH_USER ]]; then
    echo "user_credentials.json names no user; cannot install." >&2
    exit 1
  fi
  export MONARCH_USER
}

install_arch() {
  clear_logo
  gum style --foreground 3 --padding "1 0 0 $PADDING_LEFT" "Installing..."
  echo

  touch /var/log/monarch-install.log

  start_log_output

  # Set CURRENT_SCRIPT for the trap to display better when nothing is returned for some reason
  CURRENT_SCRIPT="install_base_system"
  install_base_system 2>&1 | sed -u 's/\x1b\[[0-9;]*[a-zA-Z]//g' >>/var/log/monarch-install.log
  unset CURRENT_SCRIPT
  stop_log_output
}

install_monarch() {
  chroot_bash -lc "sudo pacman -S --noconfirm --needed gum" >/dev/null
  chroot_bash -lc "source /home/$MONARCH_USER/.local/share/monarch/install.sh"
}

# Install the keys an autoinstall drive supplied, and open the door: Monarch
# enables no sshd and its firewall opens nothing beyond LocalSend and docker DNS.
# Runs after the Monarch installer, because ufw only exists once it has.
configure_ssh_access() {
  [[ -f $AUTHORIZED_KEYS ]] || return 0

  # An install that "succeeds" into a machine nobody can log into is worse than
  # one that stops with the reason on screen, so no usable key is fatal.
  local keys
  keys=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$AUTHORIZED_KEYS" |
    grep -v '^\(#\|$\)' || true)
  if [[ -z $keys ]]; then
    echo "$AUTHORIZED_KEYS contains no SSH keys" >&2
    return 1
  fi

  echo "Installing $(wc -l <<<"$keys") SSH key(s) for $MONARCH_USER"

  local ssh_dir="/mnt/home/$MONARCH_USER/.ssh"
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  printf '%s\n' "$keys" >"$ssh_dir/authorized_keys"
  chmod 600 "$ssh_dir/authorized_keys"

  # Ask the target for the uid rather than assuming 1000, and let a failure
  # abort: sshd refuses to read a root-owned authorized_keys.
  arch-chroot /mnt chown -R "$MONARCH_USER:$MONARCH_USER" "/home/$MONARCH_USER/.ssh"

  arch-chroot /mnt systemctl enable sshd.service

  # ufw cannot reach netfilter from inside a chroot and exits non-zero saying
  # so, but it writes the rule to user.rules first — and that file is what
  # ufw.service loads on first boot. Check the file, not the exit status.
  arch-chroot /mnt ufw allow ssh || true

  if ! grep -q -- '--dport 22 -j ACCEPT' /mnt/etc/ufw/user.rules; then
    echo "ufw did not record an allow rule for port 22 in /etc/ufw/user.rules" >&2
    return 1
  fi
}

reboot_if_requested() {
  if [[ -f /mnt/var/tmp/monarch-install-completed ]]; then
    reboot
  fi
}

# Set Tokyo Night color scheme for the terminal
set_tokyo_night_colors() {
  if [[ $(tty) == "/dev/tty"* ]]; then
    # Tokyo Night color palette
    echo -en "\e]P01a1b26" # black (background)
    echo -en "\e]P1f7768e" # red
    echo -en "\e]P29ece6a" # green
    echo -en "\e]P3e0af68" # yellow
    echo -en "\e]P47aa2f7" # blue
    echo -en "\e]P5bb9af7" # magenta
    echo -en "\e]P67dcfff" # cyan
    echo -en "\e]P7a9b1d6" # white
    echo -en "\e]P8414868" # bright black
    echo -en "\e]P9f7768e" # bright red
    echo -en "\e]PA9ece6a" # bright green
    echo -en "\e]PBe0af68" # bright yellow
    echo -en "\e]PC7aa2f7" # bright blue
    echo -en "\e]PDbb9af7" # bright magenta
    echo -en "\e]PE7dcfff" # bright cyan
    echo -en "\e]PFc0caf5" # bright white (foreground)

    # Set default foreground and background
    echo -en "\033[0m"
    clear
  fi
}

install_disk() {
  jq -er 'first(.disk_config.device_modifications[]? | select(.wipe == true) | .device)' user_configuration.json
}

cleanup_install_disk() {
  local disk="$1"

  if [[ -z "$disk" || ! -b "$disk" ]]; then
    echo "Could not determine install disk for cleanup" >&2
    return 1
  fi

  echo "Cleaning up existing holders on install disk: $disk"

  # Ensure that no mounts exist from past install attempts.
  findmnt -R /mnt >/dev/null && umount -R /mnt || true

  # Turn off swap and unmount anything backed by the selected disk, including
  # device-mapper children from a previous install. Active LVM/swap holders can
  # prevent the kernel from re-reading the partition table after archinstall
  # wipes and recreates it.
  while read -r dev; do
    [[ -b "$dev" ]] || continue

    swapoff "$dev" 2>/dev/null || true

    while read -r target; do
      [[ -n "$target" ]] || continue
      umount "$target" 2>/dev/null || true
    done < <(findmnt -rn -S "$dev" -o TARGET 2>/dev/null || true)
  done < <(lsblk -rnpo PATH "$disk")

  # Deactivate any LVM volume groups whose physical volumes live on the selected
  # disk. This is the common case when replacing Fedora/Alma/RHEL installs.
  while read -r dev type; do
    [[ "$type" == "disk" || "$type" == "part" || "$type" == "crypt" ]] || continue

    while read -r vg; do
      [[ -n "$vg" ]] || continue
      vgchange -an "$vg" 2>/dev/null || true
    done < <(pvs --noheadings -o vg_name "$dev" 2>/dev/null | awk '{$1=$1; print}' | sort -u)
  done < <(lsblk -rnpo PATH,TYPE "$disk")

  # Close any LUKS mappings stacked on the selected disk after filesystems and
  # swap have been released.
  while read -r dev type; do
    [[ "$type" == "crypt" ]] || continue
    cryptsetup close "$dev" 2>/dev/null || true
  done < <(lsblk -rnpo PATH,TYPE "$disk")

  blockdev --flushbufs "$disk" 2>/dev/null || true
  partprobe "$disk" 2>/dev/null || true
  udevadm settle || true
}

install_base_system() {
  # Initialize and populate the keyring
  pacman-key --init
  pacman-key --populate archlinux
  pacman-key --populate cachyos
  pacman-key --populate monarch

  # Sync the offline database so pacman can find packages
  pacman -Sy --noconfirm

  cleanup_install_disk "$(install_disk)"

  # Install using files generated by the ./configurator
  # Skip NTP and WKD sync since we're offline (keyring is pre-populated in ISO)
  archinstall \
    --config user_configuration.json \
    --creds user_credentials.json \
    --silent \
    --skip-ntp \
    --skip-wkd \
    --skip-wifi-check

  # Archinstall unmounts the ESP when it finishes. Monarch's boot finalizer
  # needs the generated Limine config and EFI artifacts available under /boot.
  if ! mountpoint -q /mnt/boot; then
    arch-chroot /mnt mount /boot
  fi

  # The installed fstab keeps the ESP root-only, but Monarch finalization runs
  # as the target user and must discover the Limine config before using sudo to
  # replace it. Temporarily allow reads and directory traversal during install.
  boot_device=$(findmnt -nro SOURCE --target /mnt/boot)
  umount /mnt/boot
  mount -t vfat -o rw,fmask=0022,dmask=0022 "$boot_device" /mnt/boot

  if ! arch-chroot -u "$MONARCH_USER" /mnt test -x /boot; then
    echo "Target user cannot access the mounted ESP" >&2
    return 1
  fi

  # After archinstall sets up the base system but before our installer runs,
  # we need to ensure the offline pacman.conf is in place
  cp /etc/pacman.conf /mnt/etc/pacman.conf

  # Mount the offline mirror so it's accessible in the chroot
  mkdir -p /mnt/var/cache/monarch/mirror/offline
  mount --bind /var/cache/monarch/mirror/offline /mnt/var/cache/monarch/mirror/offline

  # The only window where the offline repo is both configured and mounted: the
  # Monarch installer swaps this pacman.conf for the online one. -Sy because
  # archinstall wrote the target's databases and never saw this repo.
  if [[ -f $AUTHORIZED_KEYS ]]; then
    arch-chroot /mnt pacman -Sy --noconfirm --needed openssh
  fi

  # Mount the offline python directory so it's accessible in the chroot
  mkdir -p /mnt/var/cache/python/offline
  mount --bind /var/cache/python/offline /mnt/var/cache/python/offline

  # Mount the packages dir so it's accessible in the chroot
  mkdir -p /mnt/opt/packages
  mount --bind /opt/packages /mnt/opt/packages

  # No need to ask for sudo during the installation (monarch itself responsible for removing after install)
  mkdir -p /mnt/etc/sudoers.d
  cat >/mnt/etc/sudoers.d/99-monarch-installer <<EOF
root ALL=(ALL:ALL) NOPASSWD: ALL
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
$MONARCH_USER ALL=(ALL:ALL) NOPASSWD: ALL
EOF
  chmod 440 /mnt/etc/sudoers.d/99-monarch-installer

  # Copy the local monarch repo to the user's home directory
  mkdir -p /mnt/home/$MONARCH_USER/.local/share/
  # -a, not -r: without it the copy drops the executable bit, which is why the
  # chmods below exist at all.
  cp -a /root/monarch /mnt/home/$MONARCH_USER/.local/share/

  chown -R 1000:1000 /mnt/home/$MONARCH_USER/.local/

  # Belt and braces, in case the repo reached the ISO through something that
  # already lost the bit. Named directories rather than named files: the v5 port
  # moved the bar indicator scripts from default/waybar/indicators/ to
  # default/noctalia/indicators/, and the three chmods that used to name the
  # waybar paths kept failing silently against `2>/dev/null || true`. Every
  # streamed indicator was left non-executable on every installed machine, and an
  # indicator whose stream never starts is invisible rather than broken, so
  # nothing surfaced it.
  find /mnt/home/$MONARCH_USER/.local/share/monarch \
    -type f \( -path "*/bin/*" -o -path "*/default/noctalia/indicators/*" \) \
    -exec chmod +x {} \;
  chmod +x /mnt/home/$MONARCH_USER/.local/share/monarch/boot.sh 2>/dev/null || true
}

chroot_bash() {
  HOME=/home/$MONARCH_USER \
    arch-chroot -u $MONARCH_USER /mnt/ \
    env MONARCH_CHROOT_INSTALL=1 \
    MONARCH_UNATTENDED="$MONARCH_UNATTENDED" \
    MONARCH_USER_NAME="$(cat user_full_name.txt 2>/dev/null)" \
    MONARCH_USER_EMAIL="$(cat user_email_address.txt 2>/dev/null)" \
    USER="$MONARCH_USER" \
    HOME="/home/$MONARCH_USER" \
    /bin/bash "$@"
}

if [[ $(tty) == "/dev/tty1" ]]; then
  use_monarch_helpers
  run_configurator
  install_arch
  install_monarch
  configure_ssh_access
  reboot_if_requested
fi
