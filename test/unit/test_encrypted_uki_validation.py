"""Regression checks for encrypted UKIs handed to the firmware."""

import sys
import types
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/monarch-iso"))
sys.modules["orchestrator.archinstall_adapter"] = types.ModuleType("orchestrator.archinstall_adapter")

from orchestrator import phases_impl  # noqa: E402


class EncryptedUkiValidationTest(unittest.TestCase):
    def test_rejects_the_broken_installed_uki_pattern(self):
        config = "HOOKS=(base systemd block filesystems fsck)"
        archive = "usr/bin/fsck\nusr/bin/systemd\n"

        with self.assertRaisesRegex(RuntimeError, "cannot unlock an encrypted root"):
            phases_impl._assert_encrypted_uki_contents("monarch.efi", config, archive)

    def test_accepts_busybox_encrypt_and_cryptsetup(self):
        config = "HOOKS=(base udev block encrypt filesystems fsck)"
        archive = "usr/bin/cryptsetup\nhooks/encrypt\n"

        phases_impl._assert_encrypted_uki_contents("monarch.efi", config, archive)

    def test_accepts_systemd_sd_encrypt_and_cryptsetup(self):
        config = "HOOKS=(base systemd block sd-encrypt filesystems fsck)"
        archive = "usr/bin/cryptsetup\nusr/lib/systemd/system-generators/systemd-cryptsetup-generator\n"

        phases_impl._assert_encrypted_uki_contents("monarch.efi", config, archive)


if __name__ == "__main__":
    unittest.main()
