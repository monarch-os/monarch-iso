# Monarch ISO

Monarch ISO is the installation media and development toolkit for
[Monarch OS](https://www.monarchlinux.com/). It builds a CachyOS-based live ISO,
collects installation choices through a `gum` configurator, installs the base
system with archinstall, and then runs the Monarch installer in the target.

The installed system uses the `linux-cachyos` kernel, Btrfs subvolumes, optional
LUKS encryption, and Limine. Both legacy BIOS and UEFI machines can boot the
x86-64 installation media.

## What it supports

- A full-disk install on BIOS or UEFI, encrypted by default in the interactive
  configurator.
- A UEFI-only free-space install alongside existing partitions. Monarch creates
  its own 2 GiB EFI System Partition and Btrfs root inside a contiguous region
  of at least 32 GiB without adopting or formatting the Windows ESP.
- BitLocker detection before a free-space install. BitLocker must be completely
  disabled and the volume decrypted; suspending it is not sufficient.
- Account creation during installation or deferred owner provisioning on first
  boot.
- A full or reduced software profile. The reduced profile keeps the Monarch
  desktop but omits optional applications, web apps, terminal wrappers, and
  security tools.
- Unattended full-disk installation from a `cidata` drive, including optional
  SSH access and a one-time Tailscale join.
- Installation without a network connection. Pacman and Python package caches
  required by the installer are included in the ISO.
- A phase-aware install dashboard with one combined log, boot validation,
  install-media corruption diagnosis, and recovery actions on failure.
- Hibernation setup, encrypted-install autologin, and a read-only Btrfs
  `@factory` snapshot used by Monarch's factory-reset flow.
- QEMU launchers, reusable VM snapshots, interactive acceptance tests, and
  cidata-driven integration tests.
- Signing, checksumming, and uploading release images to the Monarch R2 bucket.

## Download

[Download the latest Monarch beta ISO](https://iso.monarchlinux.com/monarch-nightly.iso).

## Interactive installation

Boot the ISO and follow the configurator on tty1. It asks for the keyboard,
owner, hostname, timezone, software profile, target disk, installation layout,
and encryption choice before changing the disk.

Full-disk and free-space installs both start encrypted. On the final disk
confirmation screen, press `Ctrl+C` to toggle encryption instead of cancelling.
On the initial keyboard screen, `Ctrl+C` offers deferred provisioning: no owner
is written into the image, and the owner completes setup on first boot.

The free-space path is offered only when the ISO was booted in UEFI mode and the
selected disk already has usable unallocated space. Use the partitioning tool to
shrink or remove partitions first, but leave the intended Monarch area
unallocated. Existing partitions are preserved.

The foreground dashboard reports each installation phase and writes the unified
log to `/var/log/monarch-install.log` in the live environment and installed
system. Before reporting success, the orchestrator validates the UKI, Limine
configuration, and kernel command line. A failed free-space install removes only
the partitions and EFI entry created by that run. When pacman rejects a package
read from the bundled mirror, the failure screen distinguishes a damaged or
misread installation medium and suggests recovery steps. It can also show the
full log, upload it when the Monarch log uploader is available, open a shell,
reboot, or power off.

## Build the ISO

The build uses `cachyos/cachyos:latest` through Docker by default and writes the
result to `release/`:

```bash
./bin/monarch-iso-make
```

The ISO contains two offline caches:

- `/var/cache/monarch/mirror/offline/` is a pruned pacman repository containing
  the exact installation transaction.
- `/var/cache/python/offline/` contains the Python packages required by the
  Monarch installer.

### Build options

| Option | Effect |
|---|---|
| `--no-cache` | Do not mount the ref-specific offline mirror cache and refresh the builder image. |
| `--keep-pkg-cache` | Preserve the host's `/var/cache/pacman/pkg` instead of clearing it before the build. Useful for unattended and repeated builds. |
| `--no-boot-offer` | Do not offer to boot the resulting ISO. |
| `--local-source MONARCH MONARCH_PKGS` | Build from two local checkouts instead of cloning them. |
| `--dev` | Explicitly select the Monarch `dev` runtime ref, which is already the default. |

### Build environment

| Variable | Default | Purpose |
|---|---|---|
| `BUILDER_CMD` | `docker` | Container command; may be a command such as `podman` or `sudo docker`. |
| `MONARCH_INSTALLER_REPO` | `https://github.com/monarch-os/monarch.git` | Full Git URL for the Monarch runtime. |
| `MONARCH_INSTALLER_REF` | `dev` | Runtime branch or tag included in the ISO. |
| `MONARCH_PKGS_REPO` | `https://github.com/monarch-os/monarch-pkgs.git` | Full Git URL for the package recipes. |
| `MONARCH_PKGS_REF` | `main` | Package-recipe branch or tag. |
| `MONARCH_ISO_BUILD_CPUS` | unset | Hard CPU limit for the complete build container. |
| `MONARCH_ISO_BUILD_MEMORY` | unset | Hard memory limit for the complete build container. |
| `MONARCH_ISO_SQUASHFS_PROCESSORS` | physical cores minus two | Compressor worker count. |
| `MONARCH_ISO_SQUASHFS_MEM` | `2G` | Squashfs compressor memory limit. |
| `MONARCH_ISO_SQUASHFS_LEVEL` | `12` | Zstd compression level for the live root. |

For example, build local changes while keeping the workstation responsive:

```bash
MONARCH_ISO_BUILD_CPUS=8 MONARCH_ISO_BUILD_MEMORY=12G \
  ./bin/monarch-iso-make --local-source ../monarch ../monarch-pkgs
```

Remote branches and tags are checked before the expensive container build
starts. The offline mirror cache is keyed by `MONARCH_INSTALLER_REF`.

## Boot an ISO in QEMU

```bash
./bin/monarch-iso-boot [release/monarch.iso] [reuse] [offline]
```

With no ISO argument, the launcher offers a file from `release/`. Unless
`reuse` is present, it creates or replaces the selected qcow2 disk and its
matching OVMF variables. `offline` removes the VM network interface and is the
normal way to verify that the bundled caches are sufficient.

| Variable | Default | Purpose |
|---|---|---|
| `MONARCH_VM_DISK` | `vm-saves/monarch-iso-boot.qcow2` | VM disk path. Its EFI variables are stored beside it as `<disk>-OVMF_VARS.4m.fd`. |
| `MONARCH_VM_DISK_SIZE` | `30G` | Size of a newly created VM disk. |
| `MONARCH_VM_CPUS` | physical cores minus two | Guest vCPU count. |
| `MONARCH_VM_MEMORY` | `4096` | Guest memory in MiB. |
| `MONARCH_VM_SSH_PORT` | `2222` | Host port forwarded to guest port 22 in online mode. |
| `MONARCH_VM_CIDATA` | unset | Path to a cidata ISO attached over USB. |
| `MONARCH_VM_SOFTWARE_GL` | unset | Render host-side OpenGL on the CPU for unreliable virgl hosts. This is not suitable for graphics or performance validation. |

The launcher disables QEMU's serial port so Plymouth uses its graphical plugin,
as it does on ordinary hardware.

## Unattended installation with cidata

`cidata` is Monarch's autoinstall interface. It is a small ISO or filesystem
labelled `cidata`, attached next to the installer ISO, that contains the same
input files produced by the interactive configurator.

At live boot, `monarch-cidata-load` waits for udev, finds `cidata` or `CIDATA`,
mounts it read-only, validates its schema, and copies the inputs into `/root`.
The wizard is then skipped. Archinstall and the Monarch orchestrator consume the
ordinary files through the ordinary installation path; there is no separate
autoinstall implementation.

> **Destructive operation:** cidata supports full-disk installs only and the
> configured target is wiped without an interactive confirmation. Verify
> `--disk` against the device name inside the guest before booting the ISO.

Free-space/protected installs are deliberately rejected from removable config.
That path determines which partitions it owns while creating them during the
current interactive boot, which lets a failed install safely roll back only
those partitions.

### Prerequisites

The helper needs `xorrisofs` from `libisoburn`, plus `jq` and `openssl`:

```bash
sudo pacman -S --needed libisoburn jq openssl
```

### Create an owner during installation

This creates `y0no`, installs the supplied SSH key, and writes
`vm-saves/cidata.iso`:

```bash
./bin/monarch-iso-cidata \
  --user y0no \
  --password 'replace-me' \
  --key ~/.ssh/id_ed25519.pub
```

For `--user`, the SSH key defaults to `~/.ssh/id_ed25519.pub` and must exist.
The installer obtains `openssh` from the bundled offline mirror, installs the
keys, enables `sshd`, and persists a `ufw allow ssh` rule for first boot.
NetworkManager already provides DHCP.

### Defer owner creation to first boot

Factory images can contain no owner credentials:

```bash
./bin/monarch-iso-cidata \
  --defer-provisioning \
  --hostname monarch-factory \
  --no-preinstalls
```

This writes a `defer-provisioning` marker instead of credentials. The first-boot
owner flow collects the keyboard and account details. No SSH key is selected by
default in this mode. An explicit `--key FILE` is staged and installed for the
new owner during that flow; sshd and its firewall rule are prepared during the
ISO install, but there is no account that can log in before owner provisioning.

`--user` and `--defer-provisioning` are mutually exclusive, and one is required.

### Attach the drive to the test VM

Use a cidata image with the regular launcher:

```bash
MONARCH_VM_CIDATA=vm-saves/cidata.iso \
  ./bin/monarch-iso-boot release/monarch.iso offline
```

The default helper target is `/dev/vda`, matching the launcher's virtio disk,
and its default declared size is `30G`, matching the launcher's VM disk. When
using Proxmox, libvirt, Packer, or physical media, attach cidata as a read-only
CD-ROM or secondary drive and set `--disk` to the actual guest device, such as
`/dev/sda`, `/dev/vda`, or `/dev/nvme0n1`. Set `--size` to the real target size;
it is used to calculate the partition layout and does not create or resize the
target disk.

The `offline` argument is optional but proves that the entire install, including
SSH and Tailscale packages when requested, comes from the ISO. Detach the cidata
drive and installer ISO after imaging.

### cidata options and defaults

```text
monarch-iso-cidata (--user NAME | --defer-provisioning) [options]
```

| Option | Default | Purpose |
|---|---|---|
| `--user NAME` | none | Owner created during installation. |
| `--defer-provisioning` | off | Install without an owner and run owner setup on first boot. |
| `--password PW` | `monarch` | Account, root, and—when enabled—LUKS password for `--user`; unused when provisioning is deferred. |
| `--key FILE` | `~/.ssh/id_ed25519.pub` with `--user`; none when deferred | OpenSSH-format public keys, one per line; comments and blank lines are ignored. |
| `--tailscale-authkey FILE` | none | File containing exactly one non-comment Tailscale auth key. |
| `--disk DEV` | `/dev/vda` | Whole guest disk to wipe and install. |
| `--size SIZE` | `30G` | Actual target size as integer bytes or with an `M`/`G` suffix. |
| `--hostname NAME` | `monarch` | Installed hostname. |
| `--timezone TZ` | host timezone, then `UTC` | IANA timezone such as `Europe/Paris`. |
| `--keyboard LAYOUT` | host console layout, then `us` | Linux console keymap. |
| `--encrypt` | off | Create a LUKS-encrypted root. |
| `--no-preinstalls` | off | Omit optional software while retaining the core Monarch desktop. |
| `--full-name NAME` | repository Git identity | Full name saved for the owner setup. |
| `--email ADDRESS` | repository Git identity | Email address saved for the owner setup. |
| `-o`, `--output FILE` | `vm-saves/cidata.iso` | Output image path. |

Unlike the interactive wizard, the cidata helper defaults to an unencrypted
install. The two encrypted modes have different first-boot behaviour:

- `--user ... --encrypt` uses the supplied password as the LUKS passphrase. The
  installed host cannot reach networking or sshd until that passphrase is
  entered on its console.
- `--defer-provisioning --encrypt` generates a throwaway LUKS passphrase inside
  the live installer and embeds a temporary auto-unlock key in the first UKI.
  Owner provisioning boots without knowing that key, creates the owner, adds
  the owner's password to LUKS, removes every temporary key slot, and rebuilds
  the UKI without auto-unlock material. Completing that owner flow still
  requires the machine's console.

Example with all deployment inputs:

```bash
./bin/monarch-iso-cidata \
  --user deploy \
  --password 'replace-me' \
  --key deploy_authorized_keys \
  --tailscale-authkey tailscale.key \
  --disk /dev/vda \
  --size 100G \
  --hostname workstation-01 \
  --timezone Europe/Paris \
  --keyboard fr \
  --encrypt \
  --full-name 'Monarch User' \
  --email user@example.com \
  --output workstation-01-cidata.iso
```

### Files on the drive

| File | Required | Purpose |
|---|---|---|
| `user_configuration.json` | yes | Versioned Monarch/archinstall configuration: whole-disk layout, encryption, hostname, timezone, keyboard, and software profile. It contains the plaintext LUKS password for an encrypted direct-user install. |
| `user_credentials.json` | unless deferred | User and root password hashes, plus another archinstall input for the plaintext LUKS password when encryption is enabled. |
| `defer-provisioning` | instead of credentials | Empty marker requesting owner creation on first boot. |
| `user_full_name.txt` | no | Owner Git full name. |
| `user_email_address.txt` | no | Owner Git email. |
| `authorized_keys` | no | OpenSSH public keys, one per line. |
| `tailscale_authkey` | no | Exactly one key for a first-boot Tailscale join. |

A valid drive must contain `user_configuration.json` and either
`user_credentials.json` or `defer-provisioning`. An incomplete drive is ignored
and the interactive wizard opens. A complete drive with an unsupported or
unsafe schema is refused instead of falling back to a potentially destructive
interpretation. Currently accepted configurations have schema version 1, mode
`full_disk`, the default whole-disk layout, Limine, and exactly one wipe target.

`bin/monarch-iso-cidata` sources
`configs/airootfs/root/write-install-config`, the same canonical writer as the
interactive configurator. Prefer the helper over maintaining JSON templates by
hand, because the archinstall schema and Monarch metadata evolve together.

### Secrets and lifecycle

Treat every generated cidata image as sensitive. Password hashes are included,
an encrypted direct-user install contains its LUKS password in plaintext, and a
Tailscale deployment key is necessarily stored in plaintext. Supplying
`--password` may also leave it in shell history and expose it briefly through
the process list.

A deferred encrypted cidata image carries no LUKS passphrase: the live installer
generates it after boot. The installed system temporarily holds the auto-unlock
material until owner provisioning successfully re-keys LUKS. That flow fails
loudly and remains retryable if the UKI cannot be rebuilt or the old key slots
cannot be retired; the factory snapshot is scrubbed of the temporary material.

The installed first-boot service deletes its copy of the Tailscale key after a
successful join and factory snapshots exclude it. That does not remove the key
from the original cidata image: revoke or expire the key and securely dispose
of the image after provisioning.

When `--tailscale-authkey` is present, Tailscale is installed from the offline
mirror. On first boot, a non-blocking service waits for the network, retries the
join every 15 seconds, removes the installed key after success, disables itself,
and permits inbound traffic on `tailscale0` through ufw.

### Build a drive manually

Manual images are useful for inspecting the contract, but must still satisfy
the validation above:

```bash
mkdir cidata
cp user_configuration.json user_credentials.json authorized_keys cidata/
xorrisofs -output cidata.iso -volid cidata -joliet -rock cidata/
```

A FAT image works as well. `mkfs.vfat` uppercases the label, which the loader
accepts. This form also needs `dosfstools` and `mtools`:

```bash
truncate -s 4M cidata.img
mkfs.vfat -n CIDATA cidata.img
mcopy -i cidata.img cidata/* ::/
```

ISO images are generally more convenient for hypervisors that expose cloud-init
or NoCloud data as a CD-ROM.

## VM snapshots

`monarch-iso-boot` stores VM disks on real storage under `vm-saves/`, not in the
usually memory-backed `/tmp`. Save and reopen installed machines with:

```bash
./bin/monarch-vm save noctalia-v5
./bin/monarch-vm list
./bin/monarch-vm boot noctalia-v5
```

A named VM is stored as `vm-saves/<name>/disk.qcow2` plus
`disk-OVMF_VARS.4m.fd`. Copies use reflinks when the filesystem supports them.
`boot` runs the saved disk in place, so guest writes persist; save another copy
first when a pristine state is required. Older flat `vm-saves/<name>.qcow2`
disks remain discoverable.

## Testing

Run all fast, VM-free tests after changing the installer:

```bash
./test/all
```

Run an unattended installation once and execute every integration scenario on
throwaway overlays:

```bash
./test/integration release/monarch.iso
./test/integration release/monarch.iso factory-reset --reuse-base
```

`test/integration` accepts `--port`, `--memory`, `--timeout`, `--reuse-base`, and
`--no-preview`.

The interactive acceptance harness drives the actual configurator through QMP
keystrokes and OCR, then runs the Monarch acceptance suite in the installed VM:

```bash
./bin/monarch-iso-test release/monarch.iso
```

Its main options are:

| Option | Purpose |
|---|---|
| `--encrypt` | Exercise the encrypted interactive flow. |
| `--provision` | Exercise deferred first-boot owner provisioning. |
| `--reuse-base` | Reuse an already installed base image. |
| `--install-only` | Stop after creating the installed base. |
| `--acceptance-autologin` | Enable test-only Niri autologin in the disposable overlay. |
| `--sync-monarch DIR` | Copy a Monarch checkout's acceptance tests into the guest. |
| `--sync-all DIR` | Also copy and run its CLI and shell suites. |
| `--port PORT` | SSH port; the VNC display is derived from it. |
| `--memory MB` | Guest memory, default `8192`. |
| `--timeout SECONDS` | Install timeout, default `2400`. |
| `--keep-running` | Leave the acceptance VM running after the suite. |
| `--no-preview` | Do not open captured screenshots. |

Stop a VM retained by `--keep-running` with:

```bash
./bin/monarch-iso-test-stop [--kill] [--port 2222]
```

To exercise free-space installation beside Windows-like data, create a
synthetic disk containing a Windows ESP, a preservation marker, and at least
64 GiB of free space:

```bash
./bin/monarch-iso-test-windows-disk [--recreate] [--gap] [release/monarch.iso]
```

`--gap` leaves a hole in GPT partition numbering to test that newly allocated
partition numbers are discovered rather than guessed. The fixture is not a
bootable Windows installation.

For quick UI work without an ISO, preview the configurator and installer
dashboard on the host:

```bash
./bin/monarch-iso-configurator
./bin/monarch-iso-installer
```

Both locate a neighbouring Monarch checkout or use `MONARCH_PATH`. The
configurator runs in dry mode and does not modify a disk.

## Release tooling

Create, sign, checksum, and upload a versioned ISO:

```bash
./bin/monarch-iso-release 1.2.0
```

The release command performs a fresh `--no-cache` build, selects the newest ISO
matching `MONARCH_INSTALLER_REF` (default `dev`), copies it to
`release/monarch-1.2.0.iso`, creates `.sig` and `.sha256` sidecars, and uploads
all three files. Use `--no-make` to reuse the newest matching build:

```bash
./bin/monarch-iso-release --no-make 1.2.0
```

The individual maintainer commands are:

| Command | Purpose |
|---|---|
| `./bin/monarch-iso-sign release/monarch.iso` | Create a detached `.sig` with the first available GPG secret key. |
| `./bin/monarch-iso-upload release/monarch.iso` | Upload the ISO and its required `.sig` and `.sha256` sidecars through the `Monarch` rclone remote. |
| `./bin/monarch-iso-rclone-config` | Install rclone and create the maintainer remote from the Monarch 1Password vault. |

`monarch-iso-rclone-config` is for authorized Monarch maintainers and requires
the 1Password CLI with access to the shared Cloudflare bucket credentials.

## Repository layout

| Path | Role |
|---|---|
| `bin/` | Host-side build, VM, cidata, test, and release commands. |
| `builder/` | Container-side ISO assembly, source-package builds, and offline mirror pruning. |
| `configs/` | Overlay applied to the upstream archiso `releng` profile. |
| `configs/airootfs/root/configurator` | Interactive installation wizard. |
| `configs/airootfs/root/write-install-config` | Canonical generator for interactive and cidata inputs. |
| `configs/airootfs/usr/share/monarch-iso/orchestrator/` | Phased installation and rollback implementation. |
| `archiso/` | Pinned upstream archiso submodule. |
| `test/` | Fast unit tests and QEMU integration scenarios. |
| `release/` | Generated ISO images and release sidecars; ignored by Git. |
| `vm-saves/` | Local VM disks, EFI variables, and cidata images; ignored by Git. |

---

Built with care by [openàsource](https://monarch-os.github.io/) and Monarch
contributors.
