import copy
import hashlib
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("limine_boot", ROOT / "test/lib/limine_boot.py")
boot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(boot)


class LimineBootTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.esp = Path(tmp.name)
        self.uki = self.esp / "EFI/Linux/monarch_linux-cachyos.efi"
        self.uki.parent.mkdir(parents=True)
        self.uki.write_bytes(b"uki")
        self.config = self.esp / "limine.conf"
        self.write_menu()

    def write_menu(self, default="2", digest=None):
        digest = digest or hashlib.blake2b(self.uki.read_bytes()).hexdigest()
        self.config.write_text(
            f"default_entry: {default}\n"
            "/+Monarch\n"
            "//linux-cachyos\n"
            "protocol: efi\n"
            f"path: boot():/EFI/Linux/monarch_linux-cachyos.efi#{digest}\n"
            "/Windows\nprotocol: efi\npath: boot():/EFI/Microsoft/Boot/bootmgfw.efi\n"
            "/Other Linux\ncomment: machine-id=foreign\nprotocol: efi\n"
            "path: boot():/EFI/Linux/foreign.efi\n"
        )

    def snapshot(self):
        return boot.snapshot(self.config, self.esp)

    def test_valid_rebuild_and_identical_rebuild(self):
        before = self.snapshot()
        boot.compare(before, self.snapshot())
        self.uki.write_bytes(b"rebuilt uki")
        self.write_menu()
        after = self.snapshot()
        self.assertNotEqual(before["files"], after["files"])
        boot.compare(before, after)

    def test_stale_hash_missing_file_and_missing_hash_fail(self):
        self.uki.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "BLAKE2b mismatch"):
            self.snapshot()
        self.uki.unlink()
        with self.assertRaises(FileNotFoundError):
            self.snapshot()
        self.uki.write_bytes(b"uki")
        self.write_menu(digest="bad")
        with self.assertRaisesRegex(ValueError, "unhashed"):
            self.snapshot()

    def test_default_must_select_monarch_uki(self):
        for default in ("1", "3", "99", "/Monarch/linux-cachyos"):
            with self.subTest(default=default):
                self.write_menu(default=default)
                with self.assertRaises(ValueError):
                    self.snapshot()

    def test_closed_groups_are_not_counted_as_visible_children(self):
        text = self.config.read_text().replace("/+Monarch", "/Monarch")
        self.config.write_text(text)
        # Entry 2 is now Windows, not the hidden Monarch kernel.
        with self.assertRaisesRegex(ValueError, "unhashed"):
            self.snapshot()

    def test_menu_and_foreign_entries_cannot_change(self):
        before = self.snapshot()
        for key in ("entries", "selected", "foreign", "files"):
            after = copy.deepcopy(before)
            if key == "selected":
                after[key] += 1
            else:
                after[key] = {} if key == "files" else []
            with self.subTest(key=key), self.assertRaises(ValueError):
                boot.compare(before, after)

    def test_real_foreign_entry_edit_is_rejected(self):
        before = self.snapshot()
        self.config.write_text(self.config.read_text().replace("machine-id=foreign", "machine-id=changed"))
        with self.assertRaisesRegex(ValueError, "foreign"):
            boot.compare(before, self.snapshot())

    def test_duplicate_os_entry_is_rejected(self):
        before = self.snapshot()
        self.config.write_text(self.config.read_text() + "/Monarch\n//new kernel\n")
        with self.assertRaisesRegex(ValueError, "entries"):
            boot.compare(before, self.snapshot())

    def test_path_cannot_escape_esp(self):
        self.config.write_text(self.config.read_text().replace(
            "/EFI/Linux/monarch_linux-cachyos.efi", "/../outside.efi"
        ))
        with self.assertRaisesRegex(ValueError, "escapes ESP"):
            self.snapshot()

    def test_other_uki_cannot_pass_as_monarch(self):
        foreign = self.uki.with_name("foreign.efi")
        foreign.write_bytes(self.uki.read_bytes())
        self.config.write_text(self.config.read_text().replace(
            "monarch_linux-cachyos.efi", "foreign.efi"
        ))
        with self.assertRaisesRegex(ValueError, "Monarch UKI"):
            self.snapshot()

    def test_empty_menu_bad_nesting_and_missing_protocol_fail(self):
        for text in ("default_entry: 1\n", "///kernel\n", self.config.read_text().replace("protocol: efi", "protocol: linux")):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.config.write_text(text)
                self.snapshot()

    def test_symlink_cannot_escape_esp(self):
        self.uki.unlink()
        self.uki.symlink_to("/etc/os-release")
        with self.assertRaisesRegex(ValueError, "escapes ESP"):
            self.snapshot()


if __name__ == "__main__":
    unittest.main()
