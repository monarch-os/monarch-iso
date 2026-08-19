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
| `builder/prune-offline-mirror.sh` | Trims the offline mirror to the exact resolved transaction before indexing |
| `test/` | `bash test/<name>-test.sh`; no framework, no container needed |
| `configs/` | Overlaid on top of `archiso/configs/releng/` — boot entries, pacman configs, `profiledef.sh`, airootfs |
| `configs/airootfs/root/configurator` | The `gum` TUI the user sees at boot; writes `user_configuration.json` / `user_credentials.json` |
| `configs/airootfs/usr/local/bin/monarch-cidata-load` | Autoinstall: loads those same files off a `cidata` drive so the TUI can be skipped |
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

The mirror is **pruned to the exact transaction** before it is indexed. The build cache is per-day but shared by every build that day, so it accumulates superseded versions and packages that have left the lists or the dependency closure. `build-iso.sh` re-resolves the filenames with `pacman -S --print --print-format '%f'` against the *same* already-synced dbpath (plain `-S` — a re-sync could pick a different version than the one `-Syw` downloaded), then pipes them to `builder/prune-offline-mirror.sh`.

This is a correctness fix as much as a size one: with several versions of a package present, `repo-add` indexes whichever the shell glob hands it first — lexical order, not version order, so pkgrel `-9` can shadow `-15`. The db is now rebuilt from scratch each time rather than added to.

The pruner refuses to delete anything if the selection is empty or if any selected package is missing from the mirror, so a partial resolution can never turn a warm-cache build into a broken ISO. `bash test/prune-offline-mirror-test.sh` covers those guards.

Ported from `omarchy-iso` `f66b6fc`, which lives on the `quattro` line, **not** on upstream `main`. Only the mechanism was taken: the surrounding code there assumes release channels (`pacman-online-${OMARCHY_MIRROR}.conf`) and locally-built packages (`LOCAL_OMARCHY_BUILD`), neither of which exists here. The upstream Python test was rewritten in bash to match the workspace convention.

# Autoinstall

A drive labeled `cidata` (the cloud-init NoCloud label, so Proxmox, libvirt and
Packer all know how to attach one) carrying the configurator's own output files
stands in for the wizard. `monarch-cidata-load` copies them into `/root` and
everything downstream runs the ordinary path against ordinary inputs — that is
the whole trick, and the reason the feature costs so little: nothing branches on
"is this an autoinstall" past that point.

`user_configuration.json` and `user_credentials.json` are both required; anything
less is not an autoinstall drive and `.automated_script.sh` falls back to the
configurator. `user_full_name.txt`, `user_email_address.txt` and
`authorized_keys` are optional there exactly as they are in the wizard. Attach
one to the test VM with `MONARCH_VM_CIDATA=cidata.iso ./bin/monarch-iso-boot`;
`README.md` has the `xorrisofs` recipe.

## SSH access

`authorized_keys` on the drive makes the installed machine reachable, and it
takes three separate things — Monarch installs no `openssh`, enables no `sshd`,
and `install/first-run/firewall.sh` runs ufw default-deny with only LocalSend and
docker DNS open. They cannot all happen at the same moment:

- **`openssh` is installed in `install_base_system`.** It is in the offline
  mirror (via `builder/archinstall.packages`) but not on the installed system,
  and the Monarch installer replaces the offline `pacman.conf` with the online
  one on its way through. The package therefore has to be pulled while the
  offline repo is still both configured and bind-mounted — with `-Sy`, because
  the target's sync databases were written by archinstall, which never saw that
  repo.
- **The keys, `sshd` and the ufw rule are done in `configure_ssh_access`**, after
  the Monarch installer, because ufw only exists once it has run. `ufw` cannot
  reach netfilter from inside a chroot and exits non-zero saying so, but it
  writes the rule to `user.rules` first and that file is what `ufw.service`
  loads on first boot — so check the file, not the exit status.

An `authorized_keys` with no usable keys fails the install. An install that
"succeeds" into a machine nobody can log into is worse than one that stops with
the reason on screen.

Note the live ISO is a different story: releng already installs `openssh` and
enables `sshd`, with `PermitRootLogin yes`. Only root's empty password stands in
the way there, and nothing in this repo changes that.

# Encryption

Full-disk encryption is the default and Ctrl+C on the disk confirmation toggles
it off rather than aborting — the same way omarchy-iso quattro offers the
choice. The configurator then omits the `disk_encryption` block from
`user_configuration.json` and the passphrase from `user_credentials.json`, and
archinstall installs to a plain btrfs root. Nothing in `monarch/` needs to know:
its mkinitcpio `HOOKS` carry `encrypt` either way (a no-op without a
`cryptdevice=` cmdline) and `monarch-drive-password` already handles a machine
with no LUKS volumes.

`test/configurator-config-test.sh` lifts the file-generating tail out of the
configurator and runs it against fake answers, because the wizard itself needs a
TTY and a malformed heredoc is otherwise invisible until an install has already
wiped a disk.

Encrypted machines only come up on the network once someone has typed the
passphrase at the console: sshd starts after the root filesystem is unlocked.
Autoinstall images meant to come up unattended want encryption off.

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
- `bash test/prune-offline-mirror-test.sh`, `bash test/cidata-load-test.sh`, `bash test/configurator-config-test.sh` — the test suites here; each runs in a tempdir and needs no container
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
- **Autoinstall is the `cidata` mechanism only.** Quattro's drive also carries
  `defer-provisioning` (user creation deferred to first boot), `tailscale_authkey`
  and `user_encrypt_installation.txt`. The first two have no equivalent here. The
  third is a flag file their orchestrator needs for decisions we do not make
  (encrypted-install SDDM autologin, final boot validation); Monarch reads the
  encryption choice straight out of `user_configuration.json`, which is the only
  place it is actually configured, so there is nothing for a second file to drift
  against.
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
