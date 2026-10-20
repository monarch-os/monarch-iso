"""Exercise the install phase against the targeted archinstall 4.5 API."""

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


class Installer45:
    def __init__(self):
        self.calls = []
        self.mount_ordered_layout = mock.Mock()

    def sanity_check(self, skip_ntp=False, skip_wkd=False):
        self.calls.append({"skip_ntp": skip_ntp, "skip_wkd": skip_wkd})


class InstallerSanityCheckTest(unittest.TestCase):
    def test_install_phase_reaches_package_cache_with_archinstall_45(self):
        for pre_mounted in (False, True):
            with self.subTest(pre_mounted=pre_mounted):
                adapter = load_adapter()
                installer = Installer45()
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
                self.assertEqual(installer.calls, [expected])
                self.assertEqual(format_disk.call_count, int(not pre_mounted))
                self.assertEqual(installer.mount_ordered_layout.call_count, int(not pre_mounted))


if __name__ == "__main__":
    unittest.main()
