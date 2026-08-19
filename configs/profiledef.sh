#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="monarch"
iso_label="MONARCH_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="Monarch <https://www.monarchlinux.com>"
iso_application="Monarch OS Installer"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('bios.syslinux' 'uefi.grub')
arch="x86_64"
pacman_conf="pacman-offline.conf"
airootfs_image_type="squashfs"

# mksquashfs otherwise takes every core and sizes its caches at 25% of physical
# RAM — ~7.6GB on a 30GB desktop — which makes the machine unusable for the
# length of a build. Leave a quarter of the cores to everything else and hold
# the caches to a fixed 2GB. Both are overridable, since CI has nothing else to
# do with the box; monarch-iso-make forwards the two variables into the builder.
squashfs_processors="${MONARCH_ISO_SQUASHFS_PROCESSORS:-$((($(nproc) * 3 + 3) / 4))}"
squashfs_mem="${MONARCH_ISO_SQUASHFS_MEM:-2G}"

# Package archives in the offline mirror are already zstd-compressed. Storing
# them in an outer stream saves little space but makes pacman decompress the
# outer layer while hashing and extracting every package during installation —
# and it is the bulk of the tree, so it dominates the build's compression cost
# for a gain of about a percent.
#
# Everything else in the live root is zstd rather than xz. Squashfs decompresses
# on the page-fault path through a single stream (CONFIG_SQUASHFS_DECOMP_SINGLE),
# where xz manages ~100MB/s against zstd's ~900MB/s, and the live root is read
# cold on every boot: kernel, plymouth, systemd, python, archinstall, gum. The
# whole ISO grows well under a percent for it, and dropping the x86 BCJ filter
# also removes one of the blockers for aarch64 support.
#
# Ported from omarchy-iso 463f862 and a8c3a67.
airootfs_image_tool_options=(
  '-comp' 'zstd'
  '-Xcompression-level' '19'
  '-b' '1M'
  '-action' 'uncompressed@subpathname(var/cache/monarch/mirror/offline)'
  '-processors' "$squashfs_processors"
  '-mem' "$squashfs_mem"
)
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/root/.gnupg"]="0:0:700"
  ["/usr/local/bin/choose-mirror"]="0:0:755"
  ["/root/configurator"]="0:0:755"
  ["/var/cache/monarch/mirror/offline/"]="0:0:775"
  ["/usr/local/bin/monarch-upload-log"]="0:0:755"
)
