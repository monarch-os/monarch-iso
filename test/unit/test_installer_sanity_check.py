"""Exercise the install phase against both archinstall sanity-check APIs."""

import ast
import importlib.util
import sys
import types
import unittest
from contextlib import nullcontext
from pathlib import Path
from unittest import mock

SOURCE = Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/monarch-iso"
sys.path.insert(0, str(SOURCE))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl  # noqa: E402


def load_adapter():
    path = SOURCE / "orchestrator/archinstall_adapter.py"
    dependencies = {}
    for node in ast.parse(path.read_text()).body:
        if isinstance(node, ast.ImportFrom) and (node.module or "").startswith("archinstall."):
            module = types.ModuleType(node.module)
            for name in node.names:
                setattr(module, name.name, object)
            dependencies[node.module] = module

    spec = importlib.util.spec_from_file_location("orchestrator._sanity_check_adapter", path)
    adapter = importlib.util.module_from_spec(spec)
    with mock.patch.dict(sys.modules, dependencies):
        spec.loader.exec_module(adapter)
    return adapter


class PackageCacheReached(Exception):
    pass


class Installer44:
    def __init__(self):
        self.calls = []
        self.mount_ordered_layout = mock.Mock()

    def sanity_check(self, offline=False, skip_ntp=False, skip_wkd=False):
        self.calls.append({"offline": offline, "skip_ntp": skip_ntp, "skip_wkd": skip_wkd})


class Installer45(Installer44):
    def sanity_check(self, skip_ntp=False, skip_wkd=False):
        self.calls.append({"skip_ntp": skip_ntp, "skip_wkd": skip_wkd})


class InstallerSanityCheckTest(unittest.TestCase):
    def test_install_phase_reaches_package_cache_with_both_apis(self):
        for installer_type in (Installer44, Installer45):
            for pre_mounted in (False, True):
                with self.subTest(api=installer_type.__name__, pre_mounted=pre_mounted):
                    adapter = load_adapter()
                    installer = installer_type()
                    config = types.SimpleNamespace(mirror_config=None)
                    ctx = types.SimpleNamespace(
                        target=Path("/unused-install-target"),
                        state={
                            "arch_config_handler": types.SimpleNamespace(config=config),
                            "mirror_handler": None,
                        },
                    )
                    with (
                        mock.patch.object(phases_impl, "arch", adapter),
                        mock.patch.object(phases_impl, "info"),
                        mock.patch.object(adapter, "is_pre_mount", return_value=pre_mounted),
                        mock.patch.object(adapter, "is_encrypted", return_value=False),
                        mock.patch.object(adapter, "perform_filesystem_operations") as format_disk,
                        mock.patch.object(adapter, "open_installer", return_value=nullcontext(installer)),
                        mock.patch.object(
                            phases_impl, "_mount_offline_package_cache", side_effect=PackageCacheReached
                        ),
                        self.assertRaises(PackageCacheReached),
                    ):
                        phases_impl.arch_install_system(ctx)

                    expected = {"skip_ntp": True, "skip_wkd": True}
                    if installer_type is Installer44:
                        expected["offline"] = True
                    self.assertEqual(installer.calls, [expected])
                    self.assertEqual(format_disk.call_count, int(not pre_mounted))
                    self.assertEqual(installer.mount_ordered_layout.call_count, int(not pre_mounted))

    def test_internal_type_error_is_not_retried(self):
        calls = []

        def sanity_check(skip_ntp=False, skip_wkd=False):
            calls.append((skip_ntp, skip_wkd))
            raise TypeError("sanity check failed internally")

        installer = types.SimpleNamespace(sanity_check=sanity_check)
        with self.assertRaisesRegex(TypeError, "sanity check failed internally"):
            load_adapter().sanity_check(installer)
        self.assertEqual(calls, [(True, True)])


if __name__ == "__main__":
    unittest.main()
