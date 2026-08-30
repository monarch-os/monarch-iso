"""Expected package totals reflect conditional target packages."""

import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/monarch-iso"))

from orchestrator import phases  # noqa: E402


class ExpectedPackageCountTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.count_file = Path(self.tmp.name) / "expected-packages"
        self.count_file.write_text("1015\n")
        self.minimal_count_file = Path(self.tmp.name) / "expected-packages-minimal"
        self.minimal_count_file.write_text("900\n")
        path_patch = mock.patch.object(
            phases,
            "Path",
            side_effect=lambda value: Path(self.tmp.name) if value == "/usr/share/monarch-iso" else Path(value),
        )
        path_patch.start()
        self.addCleanup(path_patch.stop)

    def test_baseline_excludes_conditional_tailscale(self):
        ctx = types.SimpleNamespace(tailscale_authkey_path=None, include_preinstalls=True)
        self.assertEqual(phases._expected_package_count(ctx), 1015)

    def test_tailscale_cidata_counts_installed_package(self):
        ctx = types.SimpleNamespace(tailscale_authkey_path=Path("/root/tailscale_authkey"), include_preinstalls=True)
        self.assertEqual(phases._expected_package_count(ctx), 1016)

    def test_minimal_profile_uses_its_resolved_transaction_count(self):
        ctx = types.SimpleNamespace(tailscale_authkey_path=None, include_preinstalls=False)
        self.assertEqual(phases._expected_package_count(ctx), 900)


if __name__ == "__main__":
    unittest.main()
