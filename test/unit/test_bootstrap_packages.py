"""The build and orchestrator share one ordered target bootstrap list."""

import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/monarch-iso"))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl  # noqa: E402


class BootstrapPackagesTest(unittest.TestCase):
    def test_reads_ordered_groups_from_the_bundled_build_list(self):
        source = Path(__file__).resolve().parents[2] / "builder/target-bootstrap.packages"
        with mock.patch.object(phases_impl, "TARGET_BOOTSTRAP_PACKAGES", source):
            self.assertEqual(
                phases_impl._early_bootstrap_packages(),
                [
                    "base-devel",
                    "git",
                    "limine",
                    "efibootmgr",
                    "monarch-keyring",
                    "monarch-settings",
                    "monarch",
                ],
            )
            self.assertEqual(
                phases_impl._target_bootstrap_group("early-luarocks"),
                ["lua51", "luarocks"],
            )

    def test_missing_phase_fails_instead_of_silently_skipping_packages(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "target-bootstrap.packages"
            source.write_text("# phase:other\nbase\n")
            with (
                mock.patch.object(phases_impl, "TARGET_BOOTSTRAP_PACKAGES", source),
                self.assertRaisesRegex(RuntimeError, "early-base"),
            ):
                phases_impl._target_bootstrap_group("early-base")


if __name__ == "__main__":
    unittest.main()
