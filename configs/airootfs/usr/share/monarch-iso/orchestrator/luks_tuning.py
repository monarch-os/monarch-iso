# archinstall integration (GPL-3.0-only, archinstall contributors), ported from
# omacom/omarchy-iso luks_tuning.py; attribution per upstream #202.
"""Upstream LUKS, chroot and locale tuning for the live installer."""
from __future__ import annotations

import os
from pathlib import Path
from subprocess import CalledProcessError

from archinstall.lib.command import run
from archinstall.lib.disk.luks import Luks2
from archinstall.lib.exceptions import DiskError
from archinstall.lib.log import debug

OPEN_FLAGS = ["--persistent", "--allow-discards", "--perf-no_read_workqueue"]
CMDLINE_OPTIONS = "allow-discards,no-read-workqueue"


def _unlock(self: Luks2, key_file: Path | None = None) -> None:
    debug(f"Unlocking luks2 device (monarch tuning): {self.luks_dev_path}")
    if not self.mapper_name:
        raise ValueError("mapper name missing")
    if self.is_unlocked():
        debug(f"{self.mapper_name} is already open; not deriving the key again")
        return
    key_file_arg, passphrase = self._get_passphrase_args(key_file)
    cmd = ["cryptsetup", "open", str(self.luks_dev_path), str(self.mapper_name),
           *key_file_arg, "--type", "luks2", *OPEN_FLAGS]
    try:
        result = run(cmd, input_data=passphrase)
    except CalledProcessError as err:
        raise DiskError(f'Could not unlock luks2 device "{self.luks_dev_path}": {err.stdout.decode().rstrip()}')
    debug(f"cryptsetup open output: {result.stdout.decode().rstrip()}")
    if not self.is_unlocked():
        raise DiskError(f"Failed to unlock luks2 device: {self.luks_dev_path}")


_original_lock = Luks2.lock


def _lock(self: Luks2) -> None:
    if os.environ.get("MONARCH_LUKS_KEEP_OPEN", "1") == "1":
        debug(f"keeping {self.mapper_name} open for the rest of the install")
        return
    _original_lock(self)


def _chroot_argv(self, *args: str) -> list[str]:
    return ["arch-chroot", str(self.target), *args]


def _locale_archive_has_all(target: Path) -> bool:
    try:
        wanted = []
        for line in (target / "etc" / "locale.gen").read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                wanted.append(line.split()[0])
        have = run(["arch-chroot", str(target), "localedef", "--list-archive"]).stdout.decode().split()
    except (OSError, CalledProcessError):
        return False
    norm = lambda name: name.replace("-", "").lower()
    return bool(wanted) and all(norm(w) in {norm(h) for h in have} for w in wanted)


def _run_command(self, cmd: str, peek_output: bool = False):
    from archinstall.lib.command import SysCommand
    if cmd.strip() == "locale-gen" and _locale_archive_has_all(Path(self.target)):
        debug("locale archive already holds every locale in locale.gen; skipping locale-gen")
        return SysCommand("true")
    return SysCommand(f"arch-chroot {self.target} {cmd}", peek_output=peek_output)


def _with_calibration(original_encrypt):
    def encrypt(self, *args, **kwargs):
        from archinstall.lib.disk import luks
        from .luks_calibration import format_command, stop_calibration
        stop_calibration()
        original_run = luks.run
        def calibrated_run(command, *run_args, **run_kwargs):
            return original_run(format_command(command), *run_args, **run_kwargs)
        luks.run = calibrated_run
        try:
            return original_encrypt(self, *args, **kwargs)
        finally:
            luks.run = original_run
    return encrypt


def apply() -> None:
    if os.environ.get("MONARCH_LUKS_TUNING", "1") != "1":
        return
    Luks2.encrypt = _with_calibration(Luks2.encrypt)
    Luks2.unlock = _unlock
    Luks2.lock = _lock
    from archinstall.lib.installer import Installer
    Installer._chroot_argv = _chroot_argv
    Installer.run_command = _run_command


def _luks_uuid_of(spec: str) -> str | None:
    fallback = None
    if "=" in spec:
        tag, _, value = spec.partition("=")
        dev = Path("/dev/disk") / f"by-{tag.lower()}" / value
        if tag.upper() == "UUID":
            fallback = value
    else:
        dev = Path(spec)
    if not dev.exists():
        return fallback
    try:
        return run(["blkid", "-s", "UUID", "-o", "value", str(dev)]).stdout.decode().strip() or fallback
    except CalledProcessError:
        return fallback


def with_cmdline_options(cmdline: str) -> str:
    out = []
    extra = []
    for param in cmdline.split():
        if param.startswith("cryptdevice=") and param.count(":") == 1:
            param = f"{param}:{CMDLINE_OPTIONS}"
        if param.startswith("cryptdevice="):
            spec, _, rest = param[len("cryptdevice="):].partition(":")
            name = rest.split(":")[0] or "root"
            uuid = _luks_uuid_of(spec)
            if uuid and f"rd.luks.name={uuid}=" not in cmdline:
                extra += [f"rd.luks.name={uuid}={name}",
                          f"rd.luks.options={uuid}={CMDLINE_OPTIONS.replace('allow-discards', 'discard')}"]
        out.append(param)
    return " ".join(out + extra)
