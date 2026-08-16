# Base Distribution

**Monarch is built on CachyOS, not vanilla Arch.** This is the single most important divergence from Omarchy and it touches nearly every file in this repo. Omarchy's ISO is pure Arch; Monarch's is not.

Concretely:

- The build container is `cachyos/cachyos:latest` (Omarchy uses `archlinux/archlinux:latest`). Override the runtime with `BUILDER_CMD` (defaults to `docker`).
- `configs/pacman-online.conf` puts `[cachyos]` **first** so its optimized (x86-64-v3/v4) packages win over `[core]`/`[extra]`. `core`, `extra` and `multilib` are served from CachyOS mirrors but are vanilla Arch packages signed by Arch developer keys — which is why `archlinux-keyring` is still required alongside `cachyos-keyring`.
- Three keyrings must be initialized, in this order: `archlinux-keyring`, `cachyos-keyring`, `monarch-keyring`. The `[monarch]` repo (`pkgs.monarchlinux.com`) is `SigLevel = Optional TrustAll`.
- The live ISO kernel is `linux-cachyos`, not Omarchy's `linux-t2`. Apple T2 support is handled on the installed system by `install/config/hardware/apple/fix-t2.sh` in the `monarch` repo, not by the ISO kernel.
- The configurator writes CachyOS mirrors (`mirror.cachyos.org`, `cdn.cachyos.org`) into `user_configuration.json`, not Arch/Omarchy mirrors.

When porting anything from `omarchy-iso`, assume every `archlinux`, `linux-t2`, `omarchy-keyring` and mirror reference needs translating. Do **not** reintroduce `archlinux/archlinux:latest`, `mirror.omarchy.org`, or the `omarchy-keyring` preload — the Omarchy repo, mirror and signing key were deliberately dropped.

# Layout

| Path | What it is |
|------|-----------|
| `bin/` | Host-side commands: `monarch-iso-make`, `-boot`, `-release`, `-sign`, `-upload`, `-rclone-config`, plus `monarch-vm` (QEMU snapshot manager) |
| `builder/build-iso.sh` | Runs **inside** the CachyOS container; assembles airootfs and calls `mkarchiso` |
| `builder/archinstall.packages` | Extra packages fed to the offline mirror for archinstall itself |
| `configs/` | Overlaid on top of `archiso/configs/releng/` — boot entries, pacman configs, `profiledef.sh`, airootfs |
| `configs/airootfs/root/configurator` | The `gum` TUI the user sees at boot; writes `user_configuration.json` / `user_credentials.json` |
| `configs/airootfs/root/.automated_script.sh` | Autostarted on tty1; runs the configurator, then archinstall, then the Monarch installer in the chroot |
| `archiso/` | Upstream archiso as a git submodule (currently **v88**) |
| `release/` | Built ISOs (gitignored) |

# Offline Install

The ISO installs with no network. Two offline caches are baked in:

- `/var/cache/monarch/mirror/offline/` — a full pacman repo (`offline.db.tar.gz`) built by `pacman -Syw` over `packages.x86_64` + `monarch-base.packages` + `monarch-other.packages` + `archinstall.packages`
- `/var/cache/python/offline/` — `pip download` output for `install/python.packages` (Monarch-only; Omarchy has no equivalent)

Both are bind-mounted into `/mnt` before the chroot install. `configs/pacman-offline.conf` becomes `/etc/pacman.conf` in the live environment. Consequences to keep in mind:

- Anything that reaches for the network at boot must be stripped from the airootfs (e.g. `reflector.service`).
- Adding a package to the installer means adding it to one of the `.packages` lists, or it simply will not exist at install time.
- Test the offline path explicitly: `./bin/monarch-iso-boot <iso> offline` boots QEMU with `-nic none`.

# Build / Test

```bash
./bin/monarch-iso-make            # build → ./release  (--no-cache, --no-boot-offer, --local-source, --dev)
./bin/monarch-iso-boot            # pick an ISO and boot it in QEMU  ([reuse] [offline])
./bin/monarch-vm save|load|list   # snapshot a VM mid-install
./bin/monarch-iso-release <ver>   # make + sign + upload
```

Source overrides: `MONARCH_INSTALLER_REPO` (a **full git URL**, unlike Omarchy's `owner/name`) and `MONARCH_INSTALLER_REF` (default `dev`). `--local-source` bind-mounts `$MONARCH_PATH` instead of cloning.

`dev` is the default because it is the only long-lived branch on `monarch-os/monarch` and its remote HEAD — there is no `main` or `master`. Check with `git ls-remote --heads` before assuming otherwise; a ref that does not exist fails the clone inside the container and aborts the build.

A full build takes a long time and downloads several GB. Before rebuilding, cheap checks that catch most mistakes:

- `bash -n` on every script you touched
- The configurator has a dry-run: `bash configs/airootfs/root/configurator dry` renders the TUI and prints the generated JSON without touching a disk (needs `gum` on the host)
- `jq empty user_configuration.json` on that dry-run output — a malformed heredoc silently breaks the install otherwise

# Style

Follows `monarch/AGENTS.md`: two-space indent, `[[ ]]` for string tests, `(( ))` for numeric, `#!/bin/bash` shebangs. The one exception is `configs/airootfs/root/.automated_script.sh`, which keeps archiso's `#!/usr/bin/env bash` and `set -euo pipefail`.

# Upstream Sync

This fork has **no common git ancestor** with `omarchy-iso` (history was re-initialized), so `git merge-base` and `git cherry-pick` do not work. Sync by diffing file contents:

```bash
git fetch omarchy-iso
git archive omarchy-iso/main | tar -x -C /tmp/up
diff -u /tmp/up/configs/airootfs/root/configurator configs/airootfs/root/configurator
```

Upstream naming maps to ours as `omarchy*` → `monarch*` (paths, binaries, `OMARCHY_*` env vars, `/var/cache/omarchy` → `/var/cache/monarch`).

Deliberate divergences — do not "restore" these during a sync:

- **CachyOS base** — see the top of this file.
- **No release channels.** Omarchy splits `stable` / `rc` / `edge` via `OMARCHY_MIRROR` and `pacman-online-<channel>.conf`, with per-channel build caches and `--rc` / `--quattro` flags. Monarch has a single `pacman-online.conf` and a date-stamped build cache.
- **No Omarchy repo, mirror, keyring or GPG preload** (`builder/omarchy.gpg`, `pacman-key --add`/`--lsign-key`).
- **No archinstall 4.2 / Python 3.14 sed patches.** Upstream still carries them; they were fixed upstream in archinstall 4.3 and removed here on purpose.
- **Desktop shell is Noctalia, not waybar.** Any upstream `chmod +x .../default/waybar/...` logic is dead code here.
- **The installer TUI is rebranded** (Monarch purple palette, progress bar, welcome/summary boxes, French keyboard preselected). Port upstream's *behaviour* changes into it; don't take the styling wholesale.

# VM Testing Gotchas

QEMU's default serial port makes the guest kernel register `ttyS0` as a console. Plymouth reads `/sys/class/tty/console/active`, sees a serial console, and **forces its text `details` plugin** — the graphical splash and the themed LUKS passphrase prompt silently become a plain line of text on black. Nothing about the initramfs, the HOOKS, or the UKI is wrong when this happens; `plymouth.debug` shows it plainly (`serial consoles detected, managing them with details forced`, `renderer type: 4294967295`).

`bin/monarch-iso-boot` passes `-serial none` so test VMs behave like real hardware here. If you drive QEMU by hand, pass it too, or you will chase a boot-splash bug that does not exist. `console=tty0` on the kernel cmdline is the equivalent workaround from inside a running guest — do **not** bake it into `default/limine/default.conf`, it would break installs that genuinely use a serial console.

More generally: when a symptom appears in a test VM, confirm it on real hardware before changing anything in `monarch/`.

# The Live Kernel

The ISO boots **`linux-cachyos`** on every path — systemd-boot (`configs/efiboot/`), GRUB (`configs/grub/`) and syslinux. Keep them in sync when changing kernels; a mismatch is silent, because the archiso HOOKS live in the global drop-in `configs/airootfs/etc/mkinitcpio.conf.d/archiso.conf` and therefore apply to *any* kernel installed in the airootfs, so a stray second kernel still produces a bootable image.

That is exactly how the fork carried Omarchy's `linux-t2` naming long after switching to CachyOS: releng's stock `linux` was still installed and its ~250 MB archiso initramfs shipped alongside the one nobody used. `builder/build-iso.sh` now strips `linux` and `broadcom-wl` from `packages.x86_64` — `broadcom-wl` is the only releng package that hard-depends on the stock kernel, so removing the kernel alone would let pacman drag it back in. Neither is useful: the install is fully offline and the live environment needs no Wi-Fi driver.

# Releasing

```bash
./bin/monarch-iso-release <version>              # build, sign, upload
./bin/monarch-iso-release --no-make <version>    # reuse the newest built ISO
MONARCH_INSTALLER_REF=some-branch ./bin/monarch-iso-release <version>
```

`monarch-iso-release` picks the newest `release/*x86_64-<ref>.iso`, copies it to `release/monarch-<version>.iso`, signs it and uploads it to R2. It invokes its siblings through `$BUILD_ROOT/bin/` rather than `$PATH`, so it works from any working directory.

**TODO — when `main` exists on `monarch-os/monarch`:** flip `INSTALLER_REF` in `bin/monarch-iso-release` from `dev` to `main`, and leave `bin/monarch-iso-make` on `dev`. That gives the intended split — `make` builds development, `release` builds stable — without a new flag, since the two scripts already carry the distinction. Do **not** add a `--release` flag to `monarch-iso-make`: it would duplicate `MONARCH_INSTALLER_REF`, collide in name with `monarch-iso-release`, and reintroduce by the back door the release-channel model that was deliberately dropped in `118a5cc`. Reviving channels is an architecture decision, not a flag.
