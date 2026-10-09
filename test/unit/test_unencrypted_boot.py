import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/monarch-iso"))
sys.modules.setdefault("orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter"))

from orchestrator import phases_impl


class UnencryptedBootTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name)
        files = {
            "usr/bin/limine-update": "fixture",
            "etc/default/limine": 'KERNEL_CMDLINE[default]+="root=PARTUUID=test rootflags=subvol=@ rw"\n',
            "etc/kernel/cmdline": "root=PARTUUID=test rootflags=subvol=@ rw\n",
            "etc/snapper/configs/root": "fixture",
            "boot/limine.conf": "Monarch",
            "boot/EFI/limine/limine_x64.efi": "fixture",
            "boot/EFI/Linux/monarch_linux-cachyos.efi": "fixture",
            "etc/mkinitcpio.conf.d/monarch_hooks.conf": "HOOKS=(base udev plymouth block encrypt sd-encrypt filesystems fsck btrfs-overlayfs)\n",
        }
        for name, content in files.items():
            path = self.target / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        self.ctx = types.SimpleNamespace(
            target=self.target, encrypt=False, is_protected=False, defer_provisioning=False,
            monarch_install={}, user_configuration={"kernels": ["linux-cachyos"]}, state={},
        )

    def build_hooks(self):
        result = subprocess.run(
            ["bash", "-c", 'for config in "$1"/etc/mkinitcpio.conf.d/*.conf; do source "$config"; done; printf "%s\\n" "${HOOKS[@]}"', "_", str(self.target)],
            check=True, capture_output=True, text=True,
        )
        return result.stdout.splitlines()

    def finalize(self, expected_hooks):
        run = subprocess.run
        rebuilds = []

        def execute(command, **kwargs):
            if command[-1] == "limine-update":
                with mock.patch.object(subprocess, "run", run):
                    hooks = self.build_hooks()
                self.assertEqual(hooks, expected_hooks)
                rebuilds.append(command)
            return subprocess.CompletedProcess(command, 0)

        with mock.patch.object(phases_impl.subprocess, "run", side_effect=execute):
            phases_impl.finalize_limine_boot(self.ctx)
        self.assertEqual(len(rebuilds), 1)

    def test_plain_root_filters_unlock_hooks_before_uki_rebuild(self):
        self.finalize(["base", "udev", "plymouth", "block", "filesystems", "fsck", "btrfs-overlayfs"])

    def test_encrypted_root_keeps_unlock_hooks(self):
        self.ctx.encrypt = True
        self.finalize(["base", "udev", "plymouth", "block", "encrypt", "sd-encrypt", "filesystems", "fsck", "btrfs-overlayfs"])

    def test_encrypted_install_removes_a_stale_plain_root_override(self):
        phases_impl._configure_root_encryption_hooks(self.ctx)
        self.ctx.encrypt = True
        self.finalize(["base", "udev", "plymouth", "block", "encrypt", "sd-encrypt", "filesystems", "fsck", "btrfs-overlayfs"])

    def test_validation_rejects_plain_root_uki_with_encrypt_hook(self):
        with (
            mock.patch.object(phases_impl, "_assert_boot_hooks_restored"),
            mock.patch.object(phases_impl.arch, "has_uefi", return_value=True, create=True),
            mock.patch.object(phases_impl, "_read_efibootmgr", return_value={"entries": {"0001": "Limine"}}),
            mock.patch.object(phases_impl.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout="hooks/encrypt\nusr/bin/cryptsetup\n")),
            self.assertRaisesRegex(RuntimeError, "unencrypted root"),
        ):
            phases_impl.validate_boot(self.ctx)

    def test_validation_accepts_plain_root_uki_without_encrypt_hook(self):
        with (
            mock.patch.object(phases_impl, "_assert_boot_hooks_restored"),
            mock.patch.object(phases_impl.arch, "has_uefi", return_value=True, create=True),
            mock.patch.object(phases_impl, "_read_efibootmgr", return_value={"entries": {"0001": "Limine"}}),
            mock.patch.object(phases_impl.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout="hooks/udev\nusr/bin/cryptsetup\n")),
        ):
            phases_impl.validate_boot(self.ctx)


if __name__ == "__main__":
    unittest.main()
