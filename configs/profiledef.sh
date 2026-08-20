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
# RAM — ~7.6GB on a 30GB machine — which makes it unusable for the length of a
# build. Hold the caches to a fixed 2GB and keep two cores for everything else.
#
# Count physical cores, not nproc: nproc reports SMT threads, so on an
# 8-core/16-thread laptop a "leave a quarter free" rule still asks for 12
# compression threads and oversubscribes every physical core. Note this bounds
# the compressor pool only — mksquashfs layers its reader, fragment and writer
# threads on top, so use monarch-iso-make's MONARCH_ISO_BUILD_CPUS when a hard
# ceiling on the whole build is what you want.
#
# Every knob here is overridable, since CI has nothing else to do with the box;
# monarch-iso-make forwards them all into the builder, which cannot otherwise
# see the host environment.
squashfs_cores=$(lscpu -p=CORE 2>/dev/null | grep -v '^#' | sort -u | wc -l)
[[ $squashfs_cores =~ ^[0-9]+$ ]] && ((squashfs_cores > 0)) || squashfs_cores=$(($(nproc) / 2))
((squashfs_cores > 2)) || squashfs_cores=3
squashfs_processors="${MONARCH_ISO_SQUASHFS_PROCESSORS:-$((squashfs_cores - 2))}"
squashfs_mem="${MONARCH_ISO_SQUASHFS_MEM:-2G}"

# Upstream compresses at zstd 19, the highest standard level. Measured over a
# 1.7GB live-root-shaped tree (31k files of Python and ELF) at -processors 12:
#
#   level 19   193s wall   1723s CPU   408.6MiB
#   level 15    51s wall    450s CPU   444.9MiB
#   level 12    24s wall    184s CPU   446.8MiB
#
# 19 buys its last 38MiB for 9.4x the CPU, and 15 is dominated outright by 12 —
# 2.4x the CPU for 1.9MiB. So default to 12 and let anyone who wants the
# smallest possible image ask for it; CI, with nothing else to do with the box,
# is the obvious caller. zstd decompresses at essentially the same speed at any
# level, so a lower level costs nothing at install or live-boot time, which is
# what the move to zstd was for in the first place.
squashfs_level="${MONARCH_ISO_SQUASHFS_LEVEL:-12}"

# Package archives in the offline mirror are already zstd-compressed. Storing
# them in an outer stream saves little space but makes pacman decompress the
# outer layer while hashing and extracting every package during installation —
# and it is the bulk of the tree, so it dominates the build's compression cost
# for a gain of about a percent.
#
# Everything else in the live root is zstd rather than xz. Squashfs decompresses
# on the page-fault path through a single stream (CONFIG_SQUASHFS_DECOMP_SINGLE),
# where xz manages ~100MB/s against zstd's ~900MB/s, and the live root is read
# cold on every boot: kernel, plymouth, systemd, python, archinstall, gum.
# Storing the mirror raw and moving the rest to zstd measured +0.59% of ISO size
# (7.24GB to 7.28GB); the level chosen above should add ~45MiB more. Dropping the
# x86 BCJ filter also removes one of the blockers for aarch64 support.
#
# Ported from omarchy-iso 463f862 and a8c3a67.
airootfs_image_tool_options=(
  '-comp' 'zstd'
  '-Xcompression-level' "$squashfs_level"
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
  ["/usr/local/bin/monarch-cidata-load"]="0:0:755"
)
