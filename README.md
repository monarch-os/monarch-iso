# Monarch ISO

Based on Omarchy, inspired by SkillArch

The Monarch ISO streamlines the installation of [Monarch OS](https://www.monarchlinux.com/). It includes the Monarch Configurator as a front-end to archinstall and automatically launches the [Monarch Installer](https://github.com/monarch-os/monarch) after base Arch Linux has been setup.

## Downloading the latest ISO

[Download Monarch BETA](https://iso.monarchlinux.com/monarch-nightly.iso) (6GB)

## Creating the ISO

Run `./bin/monarch-iso-make` and the output goes into `./release`.

### Environment Variables

You can customize the repositories used during the build process by passing in variables:

- `MONARCH_INSTALLER_REPO` - Repository for the installer (default: `https://github.com/monarch-os/monarch.git`)
- `MONARCH_INSTALLER_REF` - Git ref (branch/tag) for the installer (default: `main`)

Example usage:
```bash
MONARCH_INSTALLER_REPO="https://github.com/monuser/monarch-fork.git" MONARCH_INSTALLER_REF="some-feature" ./bin/monarch-iso-make
```

### Build Options

- `--no-cache` - Disables package cache for a complete build
- `--no-boot-offer` - Doesn't offer to boot the ISO after building

## Testing the ISO

Run `./bin/monarch-iso-boot [release/monarch.iso]`.

Set `MONARCH_VM_CIDATA=cidata.iso` to attach an autoinstall drive to the test VM,
and `MONARCH_VM_SSH_PORT` to forward a port other than 2222 when one VM is
already running.

### Keeping a VM around

`monarch-iso-boot` uses `vm-saves/monarch-iso-boot.qcow2` unless
`MONARCH_VM_DISK` names another, and formats it on every run — `reuse` is what
keeps an installed system. `monarch-vm` names those disks so they survive the
next build:

```bash
./bin/monarch-vm save noctalia-v5   # copy the current disk under a name
./bin/monarch-vm list               # what is saved, how big, how old
./bin/monarch-vm boot noctalia-v5   # boot it again, no ISO involved
```

A saved VM is a directory: `vm-saves/noctalia-v5/disk.qcow2` and its EFI
variables beside it. One thing to copy, move or delete. Disks kept flat in
`vm-saves/` — what `MONARCH_VM_DISK=vm-saves/foo.qcow2` writes — still list and
boot under their own name.

`boot` starts the named disk in place, so anything the guest writes stays in the
snapshot. Take a copy first (`save` again under another name) when you want a
pristine one to come back to; on btrfs that copy is instant and costs no space
until one of the two is written to.

Set `MONARCH_VM_SOFTWARE_GL=1` when the host GPU cannot be trusted with
virglrenderer — on some AMD hardware a guest desktop makes it fault and reset,
which kills QEMU. The guest still sees an accelerated virtio-gpu (niri refuses a
software renderer of its own and would show nothing), but the host draws on the
CPU.

Only for testing interface and logic. Under it you are not exercising the
graphics stack Monarch ships — no vendor driver path, no dmabuf, no explicit
sync, no VRR — and frame timings mean nothing. Release testing stays on the
accelerated path.

## Autoinstall

The shipped ISO installs itself with no keyboard when it finds its configuration
on a second drive. Attach a drive labeled `cidata` alongside the ISO and the
installer copies the config off it and skips the configurator; with no such
drive, nothing changes and the wizard runs as usual. No rebuild, no extra boot
entry.

`cidata` is the cloud-init `NoCloud` label, so Proxmox, libvirt, and Packer
already know how to attach one.

### Building the drive

```bash
./bin/monarch-iso-cidata --user y0no --key ~/.ssh/id_ed25519.pub
```

To image a machine without creating an account, defer owner provisioning to
the first boot:

```bash
./bin/monarch-iso-cidata --defer-provisioning
```

Writes `vm-saves/cidata.iso`. `--help` lists the rest: `--disk`, `--size`,
`--hostname`, `--timezone`, `--keyboard`, `--encrypt`, `--password`, `-o`. The
defaults describe a test VM — `/dev/vda`, 30G, unencrypted, this host's timezone
and keyboard layout, your git identity. Pass `--no-preinstalls` to keep the
Monarch desktop while leaving out optional applications, web apps, terminal
wrappers, and security tools.

Boot it with:

```bash
MONARCH_VM_CIDATA=vm-saves/cidata.iso ./bin/monarch-iso-boot release/monarch.iso
```

### Configuration files

The helper writes these with the configurator's own code, so a generated drive
cannot drift from what the wizard produces. Build one by hand if you need
something the flags do not cover.

| File | Required | Purpose |
|------|----------|---------|
| `user_configuration.json` | Yes | archinstall config: disk, encryption, hostname, timezone, keyboard |
| `user_credentials.json` | Yes | Username and password hash |
| `user_full_name.txt` | No | Git full name |
| `user_email_address.txt` | No | Git email |
| `authorized_keys` | No | SSH public keys in sshd's own format, one per line |

Both required files must be present, and the credentials must name a user, or
the installer falls back to the configurator. Generate the password hash with
`openssl passwd -6 "yourpassword"`.

Encryption is configured by the `disk_encryption` block inside
`user_configuration.json` — which carries the passphrase in plaintext, so treat
a drive built from an encrypted install accordingly. Drop the block for an
unencrypted install.

`authorized_keys` is the same file sshd reads — copy your own or write one key
per line:

```
ssh-ed25519 AAAA... you@host
```

When `authorized_keys` is present, the install adds `openssh` from the ISO's
bundled mirror (nothing is fetched from the network), installs the keys as the
user's `~/.ssh/authorized_keys`, enables `sshd`, and adds a `ufw allow ssh`
rule — a stock Monarch install ships none of the three, and its firewall opens
nothing beyond LocalSend and docker DNS. Networking needs nothing extra;
NetworkManager is already enabled with DHCP. An `authorized_keys` with no usable
keys fails the install rather than producing a machine nobody can reach.

On an encrypted install the machine is only reachable once the LUKS passphrase
has been typed at the console — sshd starts after the root filesystem is
unlocked. Autoinstall images meant to come up unattended want the
`disk_encryption` block left out.

### Building one by hand

```bash
mkdir cidata
cp user_configuration.json user_credentials.json authorized_keys cidata/
xorrisofs -output cidata.iso -volid cidata -joliet -rock cidata/
```

`xorrisofs` comes from `libisoburn`; `genisoimage` takes the same flags. The
installer looks the drive up by label, not by filesystem, so a FAT image works
just as well and needs no ISO tooling — note `mkfs.vfat` uppercases the label:

```bash
truncate -s 4M cidata.img && mkfs.vfat -n CIDATA cidata.img
mcopy -i cidata.img cidata/* ::/
```

An ISO is the better choice for Proxmox, libvirt and Packer, which expect to
attach a `cidata` drive as a CD-ROM.

### Booting it in the test VM

```bash
MONARCH_VM_CIDATA=cidata.iso ./bin/monarch-iso-boot release/monarch.iso
```

## Signing the ISO

Run `./bin/monarch-iso-sign [gpg-user] [release/monarch.iso]`.

## Uploading the ISO

Run `./bin/monarch-iso-upload [release/monarch.iso]`. This requires you've configured rclone (use `rclone config`).

## Full release of the ISO

Run `./bin/monarch-iso-release` to create, test, sign, and upload the ISO in one flow.

## Features

- **Interactive Configurator**: Modern user interface with gum for configuration
- **Optional Encryption**: LUKS full-disk encryption, on by default
- **Autoinstall**: unattended installs from a `cidata` drive, SSH keys included
- **Optional Preinstalls**: full Monarch experience by default, minimal software profile on request
- **Btrfs Filesystem**: With optimized subvolumes and Snapper snapshots
- **Limine Bootloader**: Modern and secure bootloader
- **Multi-architecture Support**: BIOS and UEFI
- **Smart Caching**: Cache system to speed up rebuilds

## Development

To build a development version:

```bash
./bin/monarch-iso-make --dev
```

---

Brought with ❤️ by [openàsource](https://monarch-os.github.io/) and its contributors
