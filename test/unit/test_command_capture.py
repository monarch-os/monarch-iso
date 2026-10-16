#!/usr/bin/python

"""Undecodable bytes in command output, and where tolerating them stops.

The orchestrator reads firmware and filesystem metadata out of commands whose
output is not required to be UTF-8: noise in a boot entry must not stop an
install, while a mangled identifier must stop one. These tests run stand-in
commands emitting the bytes two HP firmwares actually put in a legacy BBS entry,
so they exercise the decode itself rather than a mocked result.
"""

import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/monarch-iso"))

# phases_impl imports the archinstall adapter at module scope, which pulls in
# the archinstall library that only exists on the live ISO.
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)

from orchestrator import phases_impl  # noqa: E402
from orchestrator.command import capture, capture_identifier  # noqa: E402

# Boot0000 is the entry that aborted the install: raw bytes inside a BBS device
# path, in a legacy entry nothing in the installer reads. 0x80 and 0xe0 are the
# bytes two different HP firmwares emitted.
EFIBOOTMGR_OUTPUT = (
    b"BootCurrent: 0003\n"
    b"Timeout: 0 seconds\n"
    b"BootOrder: 2001,0003,0000\n"
    b"Boot0000* Notebook Hard Drive\tBBS(HD,\x80\x7f\xff\x04\xe0\x7f,)\n"
    b"Boot0003* Monarch\tHD(1,GPT,0d9c9d4f)/File(\\EFI\\limine\\BOOTX64.EFI)\n"
    b"Boot2001* USB Drive (UEFI)\tRC\n"
)


class CommandCaptureTest(unittest.TestCase):
    def setUp(self):
        self.bin_dir = None

    def fake_bin(self) -> Path:
        """A directory at the front of PATH, made once per test."""
        if self.bin_dir is None:
            tmp = tempfile.TemporaryDirectory()
            self.addCleanup(tmp.cleanup)
            self.bin_dir = Path(tmp.name)
            path = os.environ["PATH"]
            self.addCleanup(os.environ.__setitem__, "PATH", path)
            os.environ["PATH"] = f"{self.bin_dir}:{path}"
        return self.bin_dir

    def fake_script(self, name: str, body: str) -> None:
        script = self.fake_bin() / name
        script.write_text(f"#!/bin/sh\n{body}\n")
        script.chmod(0o755)

    def fake_command(self, name: str, output: bytes) -> None:
        """A command printing exactly these bytes, undecodable ones included."""
        payload = self.fake_bin() / f"{name}.out"
        payload.write_bytes(output)
        self.fake_script(name, f'cat "{payload}"')

    def fake_findmnt(self, source: bytes) -> None:
        """A findmnt answering per column, so the phase gets as far as SOURCE."""
        payload = self.fake_bin() / "findmnt.source"
        payload.write_bytes(source)
        self.fake_script(
            "findmnt",
            'case "$2" in\n'
            "  FSTYPE) echo btrfs ;;\n"
            "  OPTIONS) echo rw,subvol=/@ ;;\n"
            f'  SOURCE) cat "{payload}" ;;\n'
            "esac",
        )

    def test_undecodable_bytes_are_replaced_rather_than_raised(self):
        self.fake_command("monarch-not-utf8", b"before\x80after\n")
        self.assertEqual(capture(["monarch-not-utf8"]).stdout, "before�after\n")

    def test_efibootmgr_entries_parse_around_a_legacy_bbs_entry(self):
        self.fake_command("efibootmgr", EFIBOOTMGR_OUTPUT)

        state = phases_impl._read_efibootmgr()

        self.assertEqual(state["order"], ["2001", "0003", "0000"])
        self.assertEqual(phases_impl._find_label_entries(state["entries"], "Monarch"), ["0003"])
        self.assertTrue(state["entries"]["0000"].startswith("Notebook Hard Drive"))

    def test_registering_monarch_never_deletes_foreign_limine_entries(self):
        pre_state = {
            "entries": {
                "0001": "Limine\tHD(1,GPT,foreign)/File(\\EFI\\limine\\limine_x64.efi)",
                "0002": "Windows Boot Manager\tHD(1,GPT,windows)",
            },
            "order": ["0002", "0001"],
        }
        post_state = {
            "entries": {
                **pre_state["entries"],
                "0003": "Limine\tHD(3,GPT,monarch,0x800,0x100)/File(\\EFI\\limine\\limine_x64.efi)",
            },
            "order": ["0003", "0002", "0001"],
        }
        ctx = types.SimpleNamespace(state={})

        with (
            mock.patch.object(phases_impl, "_read_efibootmgr", return_value=post_state),
            mock.patch.object(
                phases_impl.subprocess,
                "run",
                return_value=CompletedProcess([], 0, stdout="", stderr=""),
            ) as run,
        ):
            phases_impl._register_limine_efi_entry(
                Path("/dev/nvme0n1"), 3, "\\EFI\\limine\\limine_x64.efi",
                ctx=ctx,
                pre_state=pre_state,
                esp_guid="monarch",
            )

        commands = [call.args[0] for call in run.call_args_list]
        self.assertFalse(any("--delete-bootnum" in command for command in commands))
        self.assertIn(["efibootmgr", "--bootorder", "0003,0002,0001"], commands)
        self.assertEqual(
            ctx.state["efi_boot_rollback"],
            {"created_entry": "0003", "previous_order": ["0002", "0001"]},
        )

    def test_invalid_firmware_diagnostics_do_not_hide_created_entry_ownership(self):
        directory = self.fake_bin()
        guid = "12345678-1234-1234-1234-123456789abc"
        loader = "\\EFI\\limine\\limine_x64.efi"
        before = (
            "BootOrder: 0002,0001\n"
            f"Boot0001* Limine\tHD(1,GPT,foreign,0x800,0x100)/File({loader})\n"
            "Boot0002* Windows Boot Manager\tHD(1,GPT,windows,0x800,0x100)\n"
        )
        (directory / "before").write_text(before)
        (directory / "after").write_text(
            before + f"Boot0003* Limine\tHD(3,GPT,{guid},0x800,0x100)/File({loader})\n"
        )
        (directory / "diagnostic").write_bytes(b"firmware refused\x80\xff\n")
        for creates_entry in (False, True):
            with self.subTest(creates_entry=creates_entry):
                (directory / "created").unlink(missing_ok=True)
                (directory / "calls").write_text("")
                create_action = f'touch "{directory}/created"' if creates_entry else ":"
                self.fake_script(
                    "efibootmgr",
                    f'echo "$*" >> "{directory}/calls"\n'
                    'case "$1" in\n'
                    f'  --create) {create_action}; cat "{directory}/diagnostic" >&2; exit 1 ;;\n'
                    f'  --bootorder) cat "{directory}/diagnostic" >&2; cat "{directory}/diagnostic"; exit 1 ;;\n'
                    '  --bootnum) exit 0 ;;\n'
                    f'  *) if test -e "{directory}/created"; then cat "{directory}/after"; else cat "{directory}/before"; fi ;;\n'
                    'esac',
                )
                ctx = types.SimpleNamespace(state={})
                with mock.patch.object(phases_impl, "error") as warning:
                    phases_impl._register_limine_efi_entry(
                        Path("/dev/sda"), 3, loader, ctx=ctx, esp_guid=guid,
                    )
                warnings = "\n".join(call.args[0] for call in warning.call_args_list)
                self.assertIn("firmware refused��", warnings)
                if creates_entry:
                    self.assertIn("refused BootOrder", warnings)
                    self.assertEqual(ctx.state["efi_boot_rollback"], {
                        "created_entry": "0003", "previous_order": ["0002", "0001"],
                    })
                    phases_impl._rollback_protected_efi_entry(ctx)
                    calls = (directory / "calls").read_text().splitlines()
                    self.assertIn("--bootorder 0003,0002,0001", calls)
                    self.assertIn("--bootorder 0002,0001", calls)
                    self.assertEqual(
                        [call for call in calls if "--delete-bootnum" in call],
                        ["--bootnum 0003 --delete-bootnum"],
                    )
                else:
                    self.assertNotIn("efi_boot_rollback", ctx.state)
                    self.assertNotIn("--bootorder", (directory / "calls").read_text())

    def test_a_mangled_identifier_stops_the_install_rather_than_reaching_fstab(self):
        # _validate_pre_mounted_filesystems reads the UUID back from this same
        # command, so a replaced byte would agree with itself all the way to a
        # machine that cannot find its root.
        self.fake_command("blkid", b"1a2b3c4d-\x80-dead-beef\n")

        with self.assertRaises(RuntimeError) as raised:
            phases_impl._blkid_uuid("/dev/sda2")

        self.assertIn("the UUID of /dev/sda2 is not valid text", str(raised.exception))

    def test_a_mangled_btrfs_device_is_never_handed_to_mount(self):
        # create_factory_snapshot mounts this device and deletes subvolumes
        # under it; a replaced byte must stop the phase before that, not turn
        # into an opaque mount failure.
        self.fake_findmnt(source=b"/dev/sda\xe02[/@]")
        ctx = types.SimpleNamespace(target=Path("/mnt"), state_dir=Path("/run/monarch"))

        with mock.patch.object(phases_impl, "info"), self.assertRaises(RuntimeError) as raised:
            phases_impl.create_factory_snapshot(ctx)

        self.assertIn("is not valid text", str(raised.exception))

    def test_a_clean_identifier_is_returned_unchanged(self):
        self.fake_command("blkid", b"1a2b3c4d-0e5f-dead-beef\n")
        self.assertEqual(
            capture_identifier(["blkid"], "the UUID"), "1a2b3c4d-0e5f-dead-beef"
        )


if __name__ == "__main__":
    unittest.main()
