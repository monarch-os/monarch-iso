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
        path_patch = mock.patch.object(phases, "Path", return_value=self.count_file)
        path_patch.start()
        self.addCleanup(path_patch.stop)

    def test_baseline_excludes_conditional_tailscale(self):
        ctx = types.SimpleNamespace(tailscale_authkey_path=None)
        self.assertEqual(phases._expected_package_count(ctx), 1015)

    def test_tailscale_cidata_counts_installed_package(self):
        ctx = types.SimpleNamespace(tailscale_authkey_path=Path("/root/tailscale_authkey"))
        self.assertEqual(phases._expected_package_count(ctx), 1016)


if __name__ == "__main__":
    unittest.main()
