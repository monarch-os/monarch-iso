import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/monarch-iso"))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)
from orchestrator import main, phases_impl
from orchestrator.phases import PhaseError, run


class MediaVerificationGateTest(unittest.TestCase):
    def test_full_disk_refuses_to_prepare_target_after_failed_hash(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        ctx = types.SimpleNamespace(state={}, state_dir=Path(tmp.name), target=Path(tmp.name) / "target")
        with patch.object(main, "capture", return_value=subprocess.CompletedProcess([], 1, "", "corrupt package")), \
                patch.object(phases_impl, "prepare_live") as prepare, \
                patch.object(phases_impl, "arch_install_system") as install:
            with self.assertRaisesRegex(PhaseError, "corrupt package"):
                run(ctx, main.build_phases(ctx))
        prepare.assert_not_called()
        install.assert_not_called()

    def test_full_disk_waits_for_successful_checksum_verdict(self):
        ctx = types.SimpleNamespace(state={})
        with patch.object(main, "capture", return_value=subprocess.CompletedProcess([], 0, "verified", "")) as verify:
            name, phase = main.build_phases(ctx)[0]
            self.assertEqual(name, "Verifying install medium")
            phase(ctx)
        verify.assert_called_once_with(["monarch-wait-mirror-verify"])
        self.assertTrue(ctx.state["media_verified"])

    def configurator_function(self, name):
        text = (ROOT / "configs/airootfs/root/configurator").read_text()
        return text.split(f"{name}() {{", 1)[1].split("\n}", 1)[0]

    def run_configurator_gate(self, function, verdict, dry=False):
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "disk-touched"
            script = f"""
monarch-wait-mirror-verify() {{ return {verdict}; }}
abort() {{ exit 37; }}
step() {{ touch "$MARKER"; exit 99; }}
gum() {{ return 0; }}
clear() {{ :; }}
cfdisk() {{ touch "$MARKER"; exit 99; }}
say() {{ :; }}
write_protected_install_config() {{ :; }}
disk=/dev/test
needs_mklabel=false
encrypt_installation=false
target_function() {{{self.configurator_function(function)}
}}
target_function {'dry' if dry else ''}
"""
            result = subprocess.run(
                ["bash", "-c", script], env={**os.environ, "MARKER": str(marker)},
                capture_output=True, text=True,
            )
            return result.returncode, marker.exists()

    def test_protected_install_stops_before_first_disk_step(self):
        self.assertEqual(self.run_configurator_gate("run_partition_execute", 1), (37, False))
        self.assertEqual(self.run_configurator_gate("run_partition_execute", 0), (99, True))

    def test_protected_dry_run_does_not_need_live_verifier(self):
        self.assertEqual(self.run_configurator_gate("run_partition_execute", 1, dry=True), (0, False))

    def test_manual_partition_editor_is_also_gated(self):
        # step renders the heading here, rather than performing a disk operation.
        body = self.configurator_function("open_partition_tool")
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "cfdisk"
            for verdict in (1, 0):
                script = f"""
step() {{ :; }}
gum() {{ return 0; }}
clear() {{ :; }}
monarch-wait-mirror-verify() {{ return {verdict}; }}
cfdisk() {{ touch "$MARKER"; exit 99; }}
target_function() {{{body}
}}
target_function
"""
                result = subprocess.run(["bash", "-c", script], env={**os.environ, "MARKER": str(marker)}, capture_output=True)
                self.assertEqual(marker.exists(), verdict == 0)
                self.assertEqual(result.returncode, 1 if verdict else 99)

    def test_verifier_is_enabled_on_live_image(self):
        system = ROOT / "configs/airootfs/etc/systemd/system"
        link = system / "multi-user.target.wants/monarch-mirror-verify.service"
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.resolve(), system / "monarch-mirror-verify.service")
        unit = link.read_text()
        self.assertIn("RemainAfterExit=yes", unit)
        self.assertIn("sha256sum --check --strict --quiet", unit)


if __name__ == "__main__":
    unittest.main()
