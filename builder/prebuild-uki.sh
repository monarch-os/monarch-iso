#!/bin/bash
set -euo pipefail

root=$1
cache="$root/var/lib/monarch-iso"
mkdir -p "$cache"
mapfile -t kernels < <(find "$root/usr/lib/modules" -mindepth 2 -maxdepth 2 -name pkgbase | sort)
(( ${#kernels[@]} == 1 )) || exit 0
kernel=$(cat "${kernels[0]}")
version=$(basename "$(dirname "${kernels[0]}")")

# Match archinstall's default console before embedding it in the generic UKI.
printf 'KEYMAP=us\nFONT=default8x16\n' >"$root/etc/vconsole.conf"

printf 'monarch.cmdline_room=%01780d\n' 0 >"$cache/cmdline"

# Omarchy's systemd-initramfs twin of limine-snapper-sync's busybox overlay hook.
mkdir -p "$root/usr/lib/monarch" "$root/usr/lib/initcpio/install" "$root/usr/lib/systemd/system"
cat >"$root/usr/lib/monarch/snapshot-overlay" <<'SCRIPT'
#!/bin/bash
root=/sysroot
[[ $(findmnt -no FSTYPE "$root" 2>/dev/null) == btrfs ]] || exit 0
case $(findmnt -no SOURCE "$root" 2>/dev/null) in */snapshot*) ;; *) exit 0 ;; esac
[[ $(btrfs property get -t subvol "$root" ro 2>/dev/null) == "ro=true" ]] || exit 0
echo "[snapshot-overlay] $root is a read-only btrfs snapshot; mounting an overlay"
ram=/run/monarch-snapshot-overlay
mkdir -p "$ram" && mount -t tmpfs cowspace "$ram" && mkdir -p "$ram/upper" "$ram/work" || exit 0
mount -t overlay overlay -o "lowerdir=$root,upperdir=$ram/upper,workdir=$ram/work" "$root" && echo "[snapshot-overlay] overlay mounted on $root"
exit 0
SCRIPT
chmod 0755 "$root/usr/lib/monarch/snapshot-overlay"
cat >"$root/usr/lib/initcpio/install/sd-btrfs-overlayfs" <<'INSTALL'
#!/bin/bash
build() {
  add_module btrfs
  add_module overlay
  add_binary btrfs
  add_binary findmnt
  add_binary mount
  add_binary mkdir
  add_binary bash
  add_systemd_unit monarch-snapshot-overlay.service
  add_symlink /usr/lib/systemd/system/initrd-root-fs.target.wants/monarch-snapshot-overlay.service ../monarch-snapshot-overlay.service
}
help() {
  echo 'Boot a read-only Btrfs snapshot with a writable tmpfs overlay.'
}
INSTALL
chmod 0755 "$root/usr/lib/initcpio/install/sd-btrfs-overlayfs"
cat >"$root/usr/lib/systemd/system/monarch-snapshot-overlay.service" <<'UNIT'
[Unit]
Description=Overlay for a read-only btrfs snapshot root (initrd)
DefaultDependencies=no
ConditionPathExists=/etc/initrd-release
After=sysroot.mount
Before=initrd-root-fs.target initrd-parse-etc.service
Requires=sysroot.mount

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/monarch/snapshot-overlay
UNIT
cat >"$cache/mkinitcpio.conf" <<'CONF'
MODULES=(thunderbolt)
BINARIES=()
FILES=()
HOOKS=(base systemd plymouth autodetect microcode modconf keyboard sd-vconsole block sd-encrypt filesystems fsck sd-btrfs-overlayfs)
COMPRESSION=zstd
CONF
python /configs/airootfs/usr/share/monarch-iso/orchestrator/prebuilt_uki.py "$root" "$kernel" \
  >"$cache/prebuilt-uki.json"

if ! arch-chroot "$root" mkinitcpio -k "/usr/lib/modules/$version/vmlinuz" \
  -c /var/lib/monarch-iso/mkinitcpio.conf -S autodetect --cmdline /var/lib/monarch-iso/cmdline \
  -U /var/lib/monarch-iso/prebuilt-uki.efi; then
  rm -f "$cache/prebuilt-uki.efi"
fi
if [[ -f $cache/prebuilt-uki.efi ]] && (( $(stat -c %s "$cache/prebuilt-uki.efi") > 134217728 )); then
  echo "Prebuilt UKI exceeds 128 MiB; target will build its own" >&2
  rm -f "$cache/prebuilt-uki.efi"
fi
rm -f "$cache/cmdline" "$cache/mkinitcpio.conf"
