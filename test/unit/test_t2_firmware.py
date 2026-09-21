"""T2 firmware is staged before disk cleanup and installed as a local package."""

import sys
import tempfile
import types
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/monarch-iso"))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl  # noqa: E402


class T2FirmwareTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.archive = self.root / "run/firmware-raw.tar.gz"
        self.package = self.root / "run/apple-bcm-firmware-local-1-1-any.pkg.tar.zst"
        self.target = self.root / "mnt"
        self.target.mkdir()

        for name, value in (
            ("T2_FIRMWARE_ARCHIVE", self.archive),
            ("T2_FIRMWARE_PACKAGE", self.package),
        ):
            patch = mock.patch.object(phases_impl, name, value)
            patch.start()
            self.addCleanup(patch.stop)

        info_patch = mock.patch.object(phases_impl, "info")
        self.info = info_patch.start()
        self.addCleanup(info_patch.stop)

    def context(self):
        return types.SimpleNamespace(
            target=self.target,
            state={},
            monarch_install={"storage": {}},
            user_configuration={
                "disk_config": {
                    "device_modifications": [{"device": "/dev/nvme0n1", "wipe": True}]
                }
            },
        )

    def test_stage_reads_the_selected_disk(self):
        ctx = self.context()
        with mock.patch.object(phases_impl, "_is_t2_hardware", return_value=True), mock.patch.object(
            phases_impl.subprocess,
            "run",
            return_value=CompletedProcess([], 0, "staged", ""),
        ) as run:
            phases_impl._stage_t2_firmware(ctx)

        run.assert_called_once_with(
            [
                phases_impl.T2_FIRMWARE_COMMAND,
                "stage",
                "/dev/nvme0n1",
                str(self.archive),
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_missing_prepared_archive_is_nonfatal(self):
        with mock.patch.object(phases_impl, "_is_t2_hardware", return_value=True), mock.patch.object(
            phases_impl.subprocess,
            "run",
            return_value=CompletedProcess([], 2, "", "not found"),
        ):
            phases_impl._stage_t2_firmware(self.context())

        self.info.assert_called_with(
            "warning: no macOS-prepared T2 firmware was found; internal Wi-Fi will be unavailable"
        )

    def test_install_builds_and_tracks_local_package(self):
        self.archive.parent.mkdir(parents=True)
        self.archive.write_bytes(b"prepared firmware")
        calls = []

        def run(command, **kwargs):
            calls.append(command)
            if command[1:2] == ["build"]:
                self.package.write_bytes(b"package")
            return CompletedProcess(command, 0)

        ctx = self.context()
        with mock.patch.object(phases_impl.subprocess, "run", side_effect=run), mock.patch.object(
            phases_impl, "_mask_mkinitcpio_pacman_hooks"
        ) as mask, mock.patch.object(phases_impl, "_unmask_mkinitcpio_pacman_hooks") as unmask:
            phases_impl._install_t2_firmware(ctx)

        installed = self.target / "var/cache/pacman/pkg" / self.package.name
        self.assertEqual(installed.read_bytes(), b"package")
        self.assertEqual(calls[0][1], "build")
        self.assertEqual(calls[1][0:3], ["arch-chroot", str(self.target), "pacman"])
        self.assertEqual(ctx.state["extra_packages"], ["apple-bcm-firmware-local"])
        mask.assert_called_once_with(ctx, self.target)
        unmask.assert_called_once_with(ctx, self.target)


if __name__ == "__main__":
    unittest.main()
