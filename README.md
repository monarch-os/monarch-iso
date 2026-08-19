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

Set `MONARCH_VM_CIDATA=cidata.iso` to attach an autoinstall drive to the test VM.

## Autoinstall

The shipped ISO installs itself with no keyboard when it finds its configuration
on a second drive. Attach a drive labeled `cidata` alongside the ISO and the
installer copies the config off it and skips the configurator; with no such
drive, nothing changes and the wizard runs as usual. No rebuild, no extra boot
entry.

`cidata` is the cloud-init `NoCloud` label, so Proxmox, libvirt, and Packer
already know how to attach one.

### Configuration files

These are the configurator's own output files, so the way to get a starting set
is to run one interactive install and copy what it wrote out of `/root`.

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

### Building the drive

```bash
mkdir cidata
cp user_configuration.json user_credentials.json authorized_keys cidata/
xorrisofs -output cidata.iso -volid cidata -joliet -rock cidata/
```

`xorrisofs` comes from `libisoburn`; `genisoimage` takes the same flags.

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
