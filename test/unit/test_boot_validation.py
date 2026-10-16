import sys
import tempfile
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
mounted_partition_guid = phases._mounted_partition_guid


class BootValidationTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.target = Path(tmp.name)
        self.ctx = types.SimpleNamespace(
            target=self.target, state={}, monarch_install={},
            user_configuration={"kernels": ["linux-cachyos"]},
            encrypt=False, is_protected=False, defer_provisioning=False,
        )
        self.esp = self.target / "boot"
        self.binary = self.esp / "EFI/limine/limine_x64.efi"
        self.write("boot/EFI/limine/limine_x64.efi", "limine")
        self.write("usr/share/limine/BOOTX64.EFI", "limine")
        self.write("boot/limine.conf", "Monarch")
        self.write("etc/kernel/cmdline", "root=UUID=root")
        self.write("etc/default/limine", "CUSTOM_UKI_NAME=monarch")
        self.kernel("linux-cachyos", "6.18")
        self.entries = {"0003": self.entry()}
        for name, value in (("_assert_boot_hooks_restored", None), ("_mounted_partition_guid", GUID)):
            patch = mock.patch.object(phases, name, return_value=value)
            patch.start()
            self.addCleanup(patch.stop)
        patch = mock.patch.object(phases.arch, "has_uefi", return_value=True, create=True)
        patch.start()
        self.addCleanup(patch.stop)
        patch = mock.patch.object(phases, "_read_efibootmgr", side_effect=lambda: {"entries": self.entries, "order": list(self.entries)})
        patch.start()
        self.addCleanup(patch.stop)

    def write(self, path, text):
        path = self.target / path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def kernel(self, name, release):
        self.write(f"usr/lib/modules/{release}/pkgbase", name)
        self.write(f"usr/lib/modules/{release}/build/include/config/kernel.release", release)

    def entry(self, guid=GUID, loader=LOADER):
        return f"Limine\tHD(1,GPT,{guid},0x800,0x100)/File({loader})"

    def test_selected_kernel_uki_required_even_with_other_uki(self):
        self.kernel("linux-t2", "6.19")
        self.write("boot/EFI/Linux/monarch_linux-t2.efi", "uki")
        with self.assertRaisesRegex(RuntimeError, "monarch_linux-cachyos.efi"):
            phases.validate_boot(self.ctx)
        self.write("boot/EFI/Linux/monarch_linux-cachyos.efi", "uki")
        phases.validate_boot(self.ctx)

    def test_hardware_replacement_requires_its_uki(self):
        self.ctx.user_configuration["kernels"] = ["linux-t2"]
        with self.assertRaisesRegex(RuntimeError, "missing or empty"):
            phases.validate_boot(self.ctx)
        self.write("boot/EFI/Linux/monarch_linux-cachyos.efi", "uki")
        phases.validate_boot(self.ctx)

    def test_headers_missing_or_mismatched(self):
        header = self.target / "usr/lib/modules/6.18/build/include/config/kernel.release"
        phases._validate_kernel_headers(self.ctx)
        header.write_text("6.17")
        with self.assertRaisesRegex(RuntimeError, "do not match"):
            phases._validate_kernel_headers(self.ctx)
        header.unlink()
        with self.assertRaisesRegex(RuntimeError, "no kernel headers"):
            phases._validate_kernel_headers(self.ctx)

    def test_foreign_entry_and_foreign_fallback_are_not_boot_routes(self):
        self.entries = {"0001": self.entry(guid="foreign")}
        self.write("boot/EFI/BOOT/BOOTX64.EFI", "windows")
        with self.assertRaisesRegex(RuntimeError, "no bootable route"):
            phases._validate_uefi_boot_routes(self.ctx, self.esp, self.binary)
        self.entries = {"0001": self.entry(loader="\\EFI\\other.efi")}
        with self.assertRaisesRegex(RuntimeError, "no bootable route"):
            phases._validate_uefi_boot_routes(self.ctx, self.esp, self.binary)
        self.entries = {"0001": self.entry()}
        phases._validate_uefi_boot_routes(self.ctx, self.esp, self.binary)

    def test_nvram_refusal_requires_valid_fallback(self):
        self.entries = {}
        with mock.patch.object(phases.subprocess, "run", return_value=CompletedProcess([], 1, stderr="NVRAM full")):
            phases._register_limine_efi_entry(Path("/dev/sda"), 1, LOADER, ctx=self.ctx, esp_guid=GUID)
        with self.assertRaisesRegex(RuntimeError, "no bootable route"):
            phases._validate_uefi_boot_routes(self.ctx, self.esp, self.binary)
        self.write("boot/EFI/BOOT/BOOTX64.EFI", "limine")
        phases._validate_uefi_boot_routes(self.ctx, self.esp, self.binary)

    def test_bootorder_failure_keeps_rollback_and_entry(self):
        pre = {"entries": {"0001": "Windows"}, "order": ["0001"]}
        with mock.patch.object(phases.subprocess, "run", side_effect=[CompletedProcess([], 0, stderr=""), CompletedProcess([], 1, stderr="refused")]) as run:
            phases._register_limine_efi_entry(Path("/dev/sda"), 1, LOADER, ctx=self.ctx, esp_guid=GUID, pre_state=pre)
        self.assertEqual(run.call_args_list[-1].args[0], ["efibootmgr", "--bootorder", "0003,0001"])
        self.assertEqual(self.ctx.state["efi_boot_rollback"], {"created_entry": "0003", "previous_order": ["0001"]})
        phases._validate_uefi_boot_routes(self.ctx, self.esp, self.binary)

    def test_discarded_entry_does_not_change_bootorder(self):
        self.entries = {"0001": self.entry(guid="foreign")}
        with mock.patch.object(phases.subprocess, "run", return_value=CompletedProcess([], 0, stderr="")) as run:
            phases._register_limine_efi_entry(Path("/dev/sda"), 1, LOADER, ctx=self.ctx, esp_guid=GUID)
        self.assertEqual(run.call_count, 1)
        self.assertNotIn("efi_boot_rollback", self.ctx.state)

    def test_failed_registration_readback_never_guesses_rollback_ownership(self):
        pre = {"entries": {"0001": self.entry(guid="foreign")}, "order": ["0001"]}
        failures = (phases.subprocess.CalledProcessError(1, ["efibootmgr"]), OSError("unreadable"))
        for failure in failures:
            with (
                self.subTest(failure=failure),
                mock.patch.object(phases.subprocess, "run", return_value=CompletedProcess([], 1, stderr="refused")) as run,
                mock.patch.object(phases, "_read_efibootmgr", side_effect=failure),
                mock.patch.object(phases, "error") as warning,
            ):
                phases._register_limine_efi_entry(Path("/dev/sda"), 1, LOADER, ctx=self.ctx, esp_guid=GUID, pre_state=pre)
                self.assertEqual(run.call_count, 1)
                self.assertNotIn("efi_boot_rollback", self.ctx.state)
                self.assertIn("Rollback ownership is unknown", warning.call_args.args[0])

    def test_unreadable_esp_fails_even_with_valid_fallback(self):
        self.write("boot/EFI/BOOT/BOOTX64.EFI", "limine")
        with mock.patch.object(phases, "_mounted_partition_guid", side_effect=RuntimeError("Cannot identify")):
            with self.assertRaisesRegex(RuntimeError, "Cannot identify"):
                phases._validate_uefi_boot_routes(self.ctx, self.esp, self.binary)

    def test_install_preserves_foreign_fallback(self):
        fallback = self.write("boot/EFI/BOOT/BOOTX64.EFI", "windows")
        with mock.patch.object(phases, "_register_limine_efi_entry"):
            phases._install_limine_efi(self.ctx, esp_mount="/boot", disk=Path("/dev/sda"), part=1)
        self.assertEqual(fallback.read_text(), "windows")

    def test_install_deploys_fallback_before_nvram_write(self):
        def register(*args, **kwargs):
            self.assertEqual((self.esp / "EFI/BOOT/BOOTX64.EFI").read_text(), "limine")
            self.assertEqual(kwargs["esp_guid"], GUID)
        with mock.patch.object(phases, "_register_limine_efi_entry", side_effect=register):
            phases._install_limine_efi(self.ctx, esp_mount="/boot", disk=Path("/dev/sda"), part=1)

    def test_esp_identity_requires_exact_mount_and_valid_guid(self):
        for source, guid in (("", ""), ("/dev/sda1", ""), ("/dev/sda1", "not-a-guid")):
            with mock.patch.object(phases, "capture_identifier", side_effect=[source, guid]):
                with self.assertRaisesRegex(RuntimeError, "Cannot identify"):
                    mounted_partition_guid(self.esp)
        with mock.patch.object(phases, "capture_identifier", side_effect=["/dev/sda1", GUID.upper()]) as capture:
            self.assertEqual(mounted_partition_guid(self.esp), GUID)
        self.assertIn("--mountpoint", capture.call_args_list[0].args[0])

    def test_headers_are_installed_and_checked_before_runtime_packages(self):
        config = types.SimpleNamespace(
            kernels=["linux-cachyos"], mirror_config=None, locale_config=None,
            hostname="monarch", pacman_config=None, swap=None, auth_config=None,
            app_config=None, timezone=None, ntp=False,
        )
        installer = mock.MagicMock(target=self.target)
        installer.__enter__.return_value = installer
        self.ctx.state.update(arch_config_handler=types.SimpleNamespace(config=config), mirror_handler=None)
        self.ctx.tailscale_authkey_path = None
        events = []
        installer.add_additional_packages.side_effect = lambda packages: events.append(packages)
        with ExitStack() as stack:
            for name, result in (("is_pre_mount", True), ("open_installer", installer), ("sanity_check", None), ("root_user", None)):
                stack.enter_context(mock.patch.object(phases.arch, name, return_value=result, create=True))
            for name in ("_mount_offline_package_cache", "_mask_mkinitcpio_pacman_hooks", "_unmask_mkinitcpio_pacman_hooks", "_unmount_offline_package_cache", "_configure_limine_boot", "_write_pre_mounted_fstab"):
                stack.enter_context(mock.patch.object(phases, name))
            stack.enter_context(mock.patch.object(phases, "configure_keyboard", return_value=True))
            stack.enter_context(mock.patch.object(phases, "_runtime_package_list", return_value=["runtime-dkms"]))
            stack.enter_context(mock.patch.object(phases, "_validate_kernel_headers", side_effect=lambda ctx: events.append("validated")))
            stack.enter_context(mock.patch.object(phases, "_install_early_packages", side_effect=lambda installer: events.append("early")))
            phases.arch_install_system(self.ctx)
        self.assertEqual(events, [["linux-cachyos-headers"], "validated", "early", ["runtime-dkms"]])

    def test_finalizer_disables_foreign_fallback_updates(self):
        self.write("usr/bin/limine-update", "command")
        self.write("etc/default/limine", 'KERNEL_CMDLINE[default]+="root=UUID=root"\nENABLE_LIMINE_FALLBACK=yes\n')
        self.write("etc/snapper/configs/root", "config")
        fallback = self.write("boot/EFI/BOOT/BOOTX64.EFI", "windows")
        with mock.patch.object(phases.subprocess, "run"):
            phases.finalize_limine_boot(self.ctx)
        text = (self.target / "etc/default/limine").read_text()
        self.assertEqual(phases._limine_setting(text, "ENABLE_LIMINE_FALLBACK"), "no")
        self.assertEqual(fallback.read_text(), "windows")


if __name__ == "__main__":
    unittest.main()
