"""Exercise the install phase against archinstall's sanity-check interface."""

import builtins
import importlib.util
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/monarch-iso"))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl


def load_adapter():
    source = Path(phases_impl.__file__).with_name("archinstall_adapter.py")
    spec = importlib.util.spec_from_file_location("orchestrator._sanity_adapter", source)
    adapter = importlib.util.module_from_spec(spec)
    real_import = builtins.__import__

    def import_module(name, *args, **kwargs):
        if name.startswith("archinstall."):
            return mock.Mock(name=name)
        return real_import(name, *args, **kwargs)

    with mock.patch("builtins.__import__", side_effect=import_module):
        spec.loader.exec_module(adapter)
    return adapter


class SanityChecked(Exception):
    pass


class InstallerSanityCheckTest(unittest.TestCase):
    def setUp(self):
        self.adapter = load_adapter()

    def test_full_disk_and_pre_mounted_installs_skip_online_checks(self):
        for pre_mounted in (False, True):
            with self.subTest(pre_mounted=pre_mounted):
                calls = []

                class Installer:
                    mount_ordered_layout = mock.Mock()

                    def sanity_check(self, skip_ntp=False, skip_wkd=False):
                        calls.append((skip_ntp, skip_wkd))
                        raise SanityChecked

                config = object()
                ctx = types.SimpleNamespace(
                    state={
                        "arch_config_handler": types.SimpleNamespace(config=config),
                        "mirror_handler": object(),
                    },
                    target=Path("/mnt"),
                )
                context = mock.MagicMock()
                context.__enter__.return_value = Installer()
                with (
                    mock.patch.object(phases_impl, "arch", self.adapter),
                    mock.patch.multiple(
                        phases_impl.arch,
                        is_pre_mount=mock.Mock(return_value=pre_mounted),
                        perform_filesystem_operations=mock.Mock(),
                        open_installer=mock.Mock(return_value=context),
                        create=True,
                    ),
                    self.assertRaises(SanityChecked),
                ):
                    phases_impl.arch_install_system(ctx)

                self.assertEqual(calls, [(True, True)])
                self.assertEqual(Installer.mount_ordered_layout.call_count, int(not pre_mounted))

    def test_archinstall_44_still_receives_offline(self):
        calls = []

        class Installer:
            def sanity_check(self, offline=False, skip_ntp=False, skip_wkd=False):
                calls.append((offline, skip_ntp, skip_wkd))

        self.adapter.sanity_check(Installer())
        self.assertEqual(calls, [(True, True, True)])

    def test_errors_inside_sanity_check_propagate_without_retry(self):
        calls = []

        class Installer:
            def sanity_check(self, skip_ntp=False, skip_wkd=False):
                calls.append((skip_ntp, skip_wkd))
                raise TypeError("internal failure")

        with self.assertRaisesRegex(TypeError, "internal failure"):
            self.adapter.sanity_check(Installer())
        self.assertEqual(calls, [(True, True)])


if __name__ == "__main__":
    unittest.main()
