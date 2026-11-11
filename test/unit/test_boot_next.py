import copy
import sys
import types
import unittest
from contextlib import ExitStack
from pathlib import Path
from subprocess import CompletedProcess
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/monarch-iso"))
sys.modules.setdefault("orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter"))
from orchestrator import phases_impl as phases

GUID = "12345678-1234-1234-1234-123456789abc"
LOADER = "\\EFI\\limine\\limine_x64.efi"
ENTRY = f"Limine\tHD(3,GPT,{GUID},0x800,0x100)/File({LOADER})"


class BootNextTest(unittest.TestCase):
    def firmware(self, previous=None, refusal=None, new_entries=None):
        self.ctx = types.SimpleNamespace(state={})
        self.state = {
            "entries": {"0001": "Windows Boot Manager", "0002": ENTRY.replace(GUID, "foreign")},
            "order": ["0001", "0002"], "next": previous,
        }
        self.pre = copy.deepcopy(self.state)
        self.calls = []

        def run(command, **kwargs):
            self.calls.append(command)
            flag = command[1]
            status = 0
            if flag == "--create":
                self.state["entries"].update({"0003": ENTRY} if new_entries is None else new_entries)
            elif flag == "--bootorder":
                # Model firmware accepting the write but keeping its own order.
                self.state["order"] = ["0001", "0002", "0003"]
            elif flag == "--bootnext":
                if refusal in ("error", "silent") and command[2] == "0003":
                    status = int(refusal == "error")
                else:
                    self.state["next"] = command[2]
                    status = int(refusal == "writes_then_errors" and command[2] == "0003")
            elif flag == "--delete-bootnext":
                self.state["next"] = None
            elif flag == "--bootnum":
                self.state["entries"].pop(command[2], None)
            return CompletedProcess(command, status, stdout="", stderr="refused" if status else "")

        self.fixture_stack = self.enterContext(ExitStack())
        self.run = self.fixture_stack.enter_context(mock.patch.object(phases.subprocess, "run", side_effect=run))
        self.fixture_stack.enter_context(mock.patch.object(phases, "_read_efibootmgr", side_effect=lambda: copy.deepcopy(self.state)))
        self.warning = self.fixture_stack.enter_context(mock.patch.object(phases, "error"))

    def register(self):
        phases._register_limine_efi_entry(Path("/dev/mock"), 3, LOADER, ctx=self.ctx,
                                         pre_state=self.pre, esp_guid=GUID)

    def test_one_shot_survives_reordering_and_rollback_restores_previous(self):
        self.firmware(previous="0002")
        self.register()
        self.assertEqual(self.state["order"][0], "0001")
        self.assertEqual(self.state["next"], "0003")
        phases._rollback_protected_efi_entry(self.ctx)
        self.assertEqual(self.state["next"], "0002")
        self.assertEqual(self.state["entries"], self.pre["entries"])
        calls = list(self.calls)
        phases._rollback_protected_efi_entry(self.ctx)
        self.assertEqual(self.calls, calls)

    def test_rollback_deletes_only_our_one_shot(self):
        self.firmware()
        self.register()
        phases._rollback_protected_efi_entry(self.ctx)
        self.assertIsNone(self.state["next"])
        self.assertIn(["efibootmgr", "--delete-bootnext"], self.calls)

    def test_rollback_does_not_replace_later_external_change(self):
        self.firmware(previous="0002")
        self.register()
        self.state["next"] = "0001"
        phases._rollback_protected_efi_entry(self.ctx)
        self.assertEqual(self.state["next"], "0001")

    def test_refused_and_silently_ignored_writes_warn_without_owning_next(self):
        for refusal in ("error", "silent"):
            with self.subTest(refusal=refusal):
                self.firmware(previous="0002", refusal=refusal)
                self.register()
                self.assertNotIn("previous_next", self.ctx.state["efi_boot_rollback"])
                self.assertIn("refused BootNext", self.warning.call_args.args[0])
                phases._rollback_protected_efi_entry(self.ctx)
                self.assertEqual(self.state["next"], "0002")
                self.fixture_stack.close()

    def test_failed_command_that_mutates_next_still_rolls_back(self):
        self.firmware(previous="0002", refusal="writes_then_errors")
        self.register()
        phases._rollback_protected_efi_entry(self.ctx)
        self.assertEqual(self.state["next"], "0002")

    def test_failed_readback_keeps_successful_write_owned_for_rollback(self):
        self.firmware(previous="0002")
        with mock.patch.object(phases, "_read_efibootmgr", side_effect=[
            copy.deepcopy(self.state) | {"entries": self.state["entries"] | {"0003": ENTRY}},
            OSError("unreadable"),
        ]):
            self.register()
        self.assertEqual(self.ctx.state["efi_boot_rollback"]["previous_next"], "0002")
        phases._rollback_protected_efi_entry(self.ctx)
        self.assertEqual(self.state["next"], "0002")

    def test_unchanged_preexisting_next_is_not_owned(self):
        self.firmware(previous="0003")
        self.register()
        self.assertNotIn("previous_next", self.ctx.state["efi_boot_rollback"])
        phases._rollback_protected_efi_entry(self.ctx)
        self.assertNotIn(["efibootmgr", "--delete-bootnext"], self.calls)

    def test_no_one_shot_for_absent_foreign_or_ambiguous_new_entry(self):
        for entries in ({}, {"0003": ENTRY.replace(GUID, "foreign")},
                        {"0003": ENTRY.replace(LOADER, "\\EFI\\other.efi")},
                        {"0003": ENTRY, "0004": ENTRY}):
            with self.subTest(entries=entries):
                self.firmware(previous="0002", new_entries=entries)
                self.register()
                self.assertEqual(len(self.calls), 1)
                self.assertEqual(self.state["next"], "0002")
                self.assertEqual(self.ctx.state, {})
                self.fixture_stack.close()

    def test_parser_reads_hex_bootnext_and_absence(self):
        for text, expected in (("BootNext: 00ab\n", "00AB"), ("BootOrder: 0001\n", None)):
            with mock.patch.object(phases, "capture", return_value=CompletedProcess([], 0, stdout=text)):
                self.assertEqual(phases._read_efibootmgr()["next"], expected)


if __name__ == "__main__":
    unittest.main()
