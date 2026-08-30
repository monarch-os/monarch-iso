#!/bin/bash

set -e

# Note that these are packages installed to the CachyOS container used to build the ISO.
pacman-key --init

# Install the keyrings for package verification during build.
# core/extra/multilib are served from the Cachy mirrors as vanilla Arch
# packages signed by Arch developer keys, so archlinux-keyring is required to
# verify them at -Syw download time. The [monarch] repo is defined in
# /configs/pacman-online.conf with SigLevel = Optional TrustAll.
pacman --config /configs/pacman-online.conf --noconfirm -Sy archlinux-keyring cachyos-keyring monarch-keyring
pacman-key --populate archlinux cachyos monarch
pacman --config /configs/pacman-online.conf --noconfirm -Syu archiso git sudo base-devel jq grub python-pip

# Setup build locations
build_cache_dir="/var/cache"
offline_mirror_dir="$build_cache_dir/airootfs/var/cache/monarch/mirror/offline"
offline_python_dir="$build_cache_dir/airootfs/var/cache/python/offline"
mkdir -p $build_cache_dir/
mkdir -p $offline_mirror_dir/
mkdir -p $offline_python_dir/

# We base our ISO on the official arch ISO (releng) config
cp -r /archiso/configs/releng/* $build_cache_dir/
rm "$build_cache_dir/airootfs/etc/motd"

# The ISO installs offline from the bundled mirror, so reflector has nothing to
# do but stall at boot trying to fetch a mirrorlist.
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/reflector.service"
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/reflector.service.d"
rm -rf "$build_cache_dir/airootfs/etc/xdg/reflector"

# Monarch consumes NoCloud-style cidata with monarch-cidata-load; cloud-init is
# not part of that path. releng enables it on the live system, where its late
# tty1 status output corrupts the full-screen installer dashboard and delays
# startup while it probes for a datasource that Monarch never uses.
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/cloud-init.target.wants"

# Bring in our configs
cp -r /configs/* $build_cache_dir/
printf '%s\n' "${MONARCH_INSTALLER_REF:-dev}" >"$build_cache_dir/airootfs/root/monarch_iso_ref"
if [[ ${MONARCH_INSTALL_DEBUG:-} == 1 ]]; then
  touch "$build_cache_dir/airootfs/usr/share/monarch-iso/install-debug"
fi

# Build the runtime and settings packages from the two mounted checkouts in
# local-source builds. Normal builds bootstrap the published pair below.
local_monarch_build=""
if [[ -d /monarch-source && -d /monarch-pkgs ]]; then
  bash /builder/build-monarch-package.sh "$offline_mirror_dir"
  local_monarch_build=1
fi

bootstrap_dir=/tmp/monarch-runtime-bootstrap
runtime_root=/tmp/monarch-runtime-root
rm -rf "$bootstrap_dir" "$runtime_root" /tmp/offlinedb-bootstrap
mkdir -p "$bootstrap_dir" "$runtime_root" /tmp/offlinedb-bootstrap

find_exact_package() {
  local package_dir=$1 package_name=$2 candidate

  while IFS= read -r candidate; do
    if [[ $(bash /builder/package-name.sh "$candidate" 2>/dev/null) == "$package_name" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find "$package_dir" -maxdepth 1 -type f -name '*.pkg.tar.*' -print)

  return 1
}

if [[ -n $local_monarch_build ]]; then
  runtime_package=$(find_exact_package "$offline_mirror_dir" monarch || true)
  settings_package=$(find_exact_package "$offline_mirror_dir" monarch-settings || true)
else
  pacman --config /configs/pacman-online.conf --noconfirm -Syw monarch monarch-settings \
    --cachedir "$bootstrap_dir" --dbpath /tmp/offlinedb-bootstrap >/dev/null
  runtime_package=$(find_exact_package "$bootstrap_dir" monarch || true)
  settings_package=$(find_exact_package "$bootstrap_dir" monarch-settings || true)
fi
[[ -n $runtime_package ]] || { echo "ERROR: Monarch runtime package not found" >&2; exit 1; }
[[ -n $settings_package ]] || { echo "ERROR: Monarch settings package not found" >&2; exit 1; }
bsdtar -xf "$runtime_package" -C "$runtime_root"
bsdtar -xf "$settings_package" -C "$runtime_root"

runtime_share="$runtime_root/usr/share/monarch"
for required in install/monarch-base.packages install/monarch-other.packages \
  install/monarch-preinstalls.packages \
  install/python.packages install/provisioning/setup-form.sh logo.txt; do
  [[ -f $runtime_share/$required ]] || {
    echo "ERROR: monarch package does not ship /usr/share/monarch/$required" >&2
    exit 1
  }
done

mkdir -p "$build_cache_dir/airootfs/usr/share/monarch-iso" \
  "$build_cache_dir/airootfs/usr/share/monarch" \
  "$build_cache_dir/airootfs/usr/local/bin" \
  "$build_cache_dir/airootfs/usr/share/plymouth/themes/monarch"
cp "$runtime_share/install/monarch-base.packages" "$build_cache_dir/airootfs/usr/share/monarch-iso/"
cp "$runtime_share/install/monarch-other.packages" "$build_cache_dir/airootfs/usr/share/monarch-iso/"
cp "$runtime_share/install/monarch-preinstalls.packages" "$build_cache_dir/airootfs/usr/share/monarch-iso/"
cp "$runtime_share/install/provisioning/setup-form.sh" "$build_cache_dir/airootfs/usr/share/monarch-iso/setup-form.sh"
cp "$runtime_share/logo.txt" "$build_cache_dir/airootfs/usr/share/monarch/logo.txt"
cp "$runtime_share/bin/monarch-upload-log" "$build_cache_dir/airootfs/usr/local/bin/monarch-upload-log"
cp -r "$runtime_share/default/plymouth/"* "$build_cache_dir/airootfs/usr/share/plymouth/themes/monarch/"

# Download and verify Node.js binary for offline installation
NODE_DIST_URL="https://nodejs.org/dist/latest"

# Get checksums and parse filename and SHA
NODE_SHASUMS=$(curl -fsSL "$NODE_DIST_URL/SHASUMS256.txt")
NODE_FILENAME=$(echo "$NODE_SHASUMS" | grep "linux-x64.tar.gz" | awk '{print $2}')
NODE_SHA=$(echo "$NODE_SHASUMS" | grep "linux-x64.tar.gz" | awk '{print $1}')

# Download the tarball
curl -fsSL "$NODE_DIST_URL/$NODE_FILENAME" -o "/tmp/$NODE_FILENAME"

# Verify SHA256 checksum
echo "$NODE_SHA /tmp/$NODE_FILENAME" | sha256sum -c - || {
    echo "ERROR: Node.js checksum verification failed!"
    exit 1
}

# Copy to ISO
mkdir -p "$build_cache_dir/airootfs/opt/packages/"
cp "/tmp/$NODE_FILENAME" "$build_cache_dir/airootfs/opt/packages/"

# Add our additional packages to packages.x86_64
arch_packages=(linux-cachyos git gum jq openssl plymouth tzupdate archlinux-keyring monarch-keyring cachyos-keyring)
printf '%s\n' "${arch_packages[@]}" >>"$build_cache_dir/packages.x86_64"

# The live ISO boots linux-cachyos, so releng's stock `linux` is a second kernel
# nobody boots: ~17MB of kernel plus a ~250MB archiso initramfs, copied into both
# the ISO tree and the size-constrained FAT EFI image.
#
# It cannot just be deleted — releng's broadcom-wl hard-depends on it, and it is
# the only releng package that does, so pacman would drag the kernel straight back
# in. broadcom-wl is a prebuilt module for stock linux and cannot load on the
# kernel we boot, so it has done nothing since we started booting linux-cachyos.
# The install is entirely offline and the live environment needs no Wi-Fi driver.
#
# cloud-init is also inherited from releng, but Monarch's cidata loader replaces
# its only relevant job. Anchored so linux-cachyos and linux-firmware remain.
# Upstream removes its unused stock kernel with the same mechanism.
sed -i -E '/^(linux|broadcom-wl|cloud-init)$/d' "$build_cache_dir/packages.x86_64"

# Its preset goes too: pacman's mkinitcpio hook runs `mkinitcpio -P` over every
# preset in the airootfs, and this one's kernel never arrives to build from.
rm "$build_cache_dir/airootfs/etc/mkinitcpio.d/linux.preset"

# Build list of all packages needed for the live system and target transaction.
mapfile -t all_packages < <(
  {
    cat "$build_cache_dir/packages.x86_64"
    grep -hv '^#\|^$' "$build_cache_dir/airootfs/usr/share/monarch-iso/monarch-base.packages"
    grep -hv '^#\|^$' "$build_cache_dir/airootfs/usr/share/monarch-iso/monarch-other.packages"
    grep -hv '^#\|^$' /builder/archinstall.packages
    printf '%s\n' monarch monarch-settings
  } | sort -u
)

if [[ -n $local_monarch_build ]]; then
  mapfile -t all_packages < <(printf '%s\n' "${all_packages[@]}" | grep -Fxv -e monarch -e monarch-settings)
fi

# Download all the packages to the offline mirror inside the ISO
mkdir -p /tmp/offlinedb
download_offline_packages() {
  pacman --config /configs/pacman-online.conf --noconfirm -Syw \
    "${all_packages[@]}" --cachedir "$offline_mirror_dir/" --dbpath /tmp/offlinedb --needed
}

# A repository may occasionally republish a package without changing its
# filename. Pacman detects that the persistent cached copy no longer matches
# the refreshed repository checksum and deletes it, but still fails the
# transaction. Retry once so the now-missing package is downloaded. This matters
# more now that the cache is keyed by ref and therefore lives for months.
# Mirrors omarchy-iso 3544261.
if ! download_offline_packages; then
  echo "Offline package download failed; retrying after pacman cleaned invalid cached files..." >&2
  download_offline_packages
fi

# Resolve the exact filenames chosen by the databases just synced above, and
# throw away everything else the cache holds. The build cache is keyed by ref
# and shared by every build on it, so it accumulates superseded versions and
# packages that have since left the lists or the dependency closure — all the
# more so now that it is no longer discarded daily. Note the
# plain -S: re-syncing here could resolve a different version than the one the
# -Syw above actually downloaded.
if ! resolved_package_files="$(
  pacman --config /configs/pacman-online.conf --noconfirm \
    --dbpath /tmp/offlinedb -S --print --print-format '%f' "${all_packages[@]}"
)"; then
  echo "ERROR: could not resolve the package files required by the offline mirror" >&2
  exit 1
fi

mapfile -t required_package_files <<<"$resolved_package_files"
if [[ -n $local_monarch_build ]]; then
  required_package_files+=("${runtime_package##*/}")
  required_package_files+=("${settings_package##*/}")
fi

printf '%s\n' "${required_package_files[@]}" |
  bash /builder/prune-offline-mirror.sh "$offline_mirror_dir"

# Rebuild the index from scratch rather than adding to it. With several versions
# of a package in the directory, repo-add indexes whichever the shell glob hands
# it first — lexical order, not version order, so pkgrel -9 can shadow -15.
# Pruning first makes the selection unambiguous; dropping the old db keeps sizes
# and checksums in step with the files actually shipped.
rm -f "$offline_mirror_dir"/offline.db* "$offline_mirror_dir"/offline.files*
repo-add "$offline_mirror_dir/offline.db.tar.gz" "$offline_mirror_dir/"*.pkg.tar.zst

# Record the resolved target transaction for the dashboard and post-install
# diagnostics. archinstall.packages feeds the live/offline installer and must
# not be counted as target state: several entries are hardware-conditional or
# live-only, and tailscale is installed only when cidata supplies an auth key.
mapfile -t target_packages < <(
  {
    grep -hv '^#\|^$' "$build_cache_dir/airootfs/usr/share/monarch-iso/monarch-base.packages"
    grep -hv '^#\|^$' "$build_cache_dir/airootfs/usr/share/monarch-iso/monarch-other.packages"
    printf '%s\n' monarch-keyring monarch monarch-settings
  } | sort -u
)
if [[ -n $local_monarch_build ]]; then
  mapfile -t target_packages < <(
    printf '%s\n' "${target_packages[@]}" | grep -Fxv -e monarch -e monarch-settings
  )
fi
expected_packages=$(
  pacman --config /configs/pacman-online.conf --noconfirm --dbpath /tmp/offlinedb \
    -S --print --print-format '%n' "${target_packages[@]}" | sort -u | wc -l
)
if [[ -n $local_monarch_build ]]; then
  ((expected_packages += 2))
fi
printf '%s\n' "$expected_packages" >"$build_cache_dir/airootfs/usr/share/monarch-iso/expected-packages"

mapfile -t minimal_target_packages < <(
  printf '%s\n' "${target_packages[@]}" |
    grep -Fvx -f "$build_cache_dir/airootfs/usr/share/monarch-iso/monarch-preinstalls.packages"
)
expected_minimal_packages=$(
  pacman --config /configs/pacman-online.conf --noconfirm --dbpath /tmp/offlinedb \
    -S --print --print-format '%n' "${minimal_target_packages[@]}" | sort -u | wc -l
)
if [[ -n $local_monarch_build ]]; then
  ((expected_minimal_packages += 2))
fi
printf '%s\n' "$expected_minimal_packages" >"$build_cache_dir/airootfs/usr/share/monarch-iso/expected-packages-minimal"

# Create a symlink to the offline mirror instead of duplicating it.
# mkarchiso needs packages at /var/cache/monarch/mirror/offline in the container,
# but they're actually in $build_cache_dir/airootfs/var/cache/monarch/mirror/offline
mkdir -p /var/cache/monarch/mirror
ln -s "$offline_mirror_dir" "/var/cache/monarch/mirror/offline"

# Copy the offline pacman.conf to the ISO's /etc directory so the live environment uses our
# same config when booted.
cp $build_cache_dir/pacman-offline.conf "$build_cache_dir/airootfs/etc/pacman.conf"

# Install python packages
python_packages=(pip) # Always install pip to the offline python directory as it's needed by pipx
python_packages+=($(grep -v '^#' "$runtime_share/install/python.packages" | grep -v '^$'))
pip download -d $offline_python_dir "${python_packages[@]}"

# Finally, we assemble the entire ISO
mkarchiso -v -w "$build_cache_dir/work/" -o "/out/" "$build_cache_dir/"

# Fix ownership of output files to match host user
if [ -n "$HOST_UID" ] && [ -n "$HOST_GID" ]; then
    chown -R "$HOST_UID:$HOST_GID" /out/
fi
