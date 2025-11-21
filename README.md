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

## Signing the ISO

Run `./bin/monarch-iso-sign [gpg-user] [release/monarch.iso]`.

## Uploading the ISO

Run `./bin/monarch-iso-upload [release/monarch.iso]`. This requires you've configured rclone (use `rclone config`).

## Full release of the ISO

Run `./bin/monarch-iso-release` to create, test, sign, and upload the ISO in one flow.

## Features

- **Interactive Configurator**: Modern user interface with gum for configuration
- **Automatic Encryption**: LUKS configuration with disk encryption
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
