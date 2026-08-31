#!/usr/bin/python

import re
import sys
import tempfile
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/monarch-iso"))

from orchestrator import keyboard as KEYBOARD  # noqa: E402

# The layout list lives in the Monarch runtime now, shared verbatim with the
# first-boot owner setup; build-iso.sh vendors it onto the ISO. Read it from
# wherever this checkout can see a runtime, and skip the coverage test rather
# than fail when none is around (a bare CI checkout of just this repo).
SETUP_FORM_CANDIDATES = (
    Path("/monarch-source/install/provisioning/setup-form.sh"),
    ROOT.parent / "monarch/install/provisioning/setup-form.sh",
    Path("/usr/share/monarch/install/provisioning/setup-form.sh"),
)


def supported_keymaps():
    for candidate in SETUP_FORM_CANDIDATES:
        if not candidate.is_file():
            continue
        block = re.search(
            r"MONARCH_KEYBOARD_LAYOUTS=\$'(.*?)'\n", candidate.read_text(), re.DOTALL
        )
        assert block, f"no layout list in {candidate}"
        return [line.split("|", 1)[1] for line in block.group(1).splitlines()]
    return None


SUPPORTED_KEYMAPS = supported_keymaps()


class KeyboardConfigurationTest(unittest.TestCase):
    def setUp(self):
        def fake_capture(cmd):
            if "list-keymaps" in cmd:
                layouts = SUPPORTED_KEYMAPS or ["us", "fr"]
                return CompletedProcess(cmd, 0, stdout="\n".join(layouts) + "\n", stderr="")
            root = next(arg.split("=", 1)[1] for arg in cmd if arg.startswith("--root="))
            keymap = next(arg.split("=", 1)[1] for arg in cmd if arg.startswith("--keymap="))
            (Path(root) / "etc/vconsole.conf").write_text(
                f"KEYMAP={keymap}\nXKBLAYOUT={keymap}\n"
            )
            return CompletedProcess(cmd, 0, stdout="", stderr="")

        self.capture_patch = mock.patch.object(
            KEYBOARD,
            "capture",
            side_effect=fake_capture,
        )
        self.capture_patch.start()
        self.addCleanup(self.capture_patch.stop)
    def target(self, directory: str) -> Path:
        target = Path(directory)
        (target / "etc").mkdir()
        (target / "etc/vconsole.conf").write_text(
            "KEYMAP=us\nFONT=default8x16\n"
        )
        return target

    def test_writes_keymap_and_xkb_settings_and_preserves_font(self):
        # XKBLAYOUT is load-bearing: monarch's detect-keyboard-layout.sh copies
        # it into Hyprland's kb_layout on the installed system.
        with tempfile.TemporaryDirectory() as directory:
            target = self.target(directory)
            self.assertTrue(KEYBOARD.configure_keyboard(target, "us"))
            lines = (target / "etc/vconsole.conf").read_text().splitlines()
            self.assertIn("KEYMAP=us", lines)
            self.assertIn("XKBLAYOUT=us", lines)
            self.assertEqual(lines.count("FONT=default8x16"), 1)

    def test_all_configurator_keymaps_are_known_to_localectl(self):
        if SUPPORTED_KEYMAPS is None:
            self.skipTest("no Monarch runtime checkout to read the layout list from")
        for keymap in SUPPORTED_KEYMAPS:
            with self.subTest(keymap=keymap), tempfile.TemporaryDirectory() as directory:
                target = self.target(directory)
                self.assertTrue(KEYBOARD.configure_keyboard(target, keymap))
                lines = (target / "etc/vconsole.conf").read_text().splitlines()
                self.assertIn(f"KEYMAP={keymap}", lines)
                self.assertEqual(lines.count("FONT=default8x16"), 1)

    def test_unknown_and_empty_keymaps_match_archinstall_behavior(self):
        for keymap, expected in (("definitely-not-a-keymap", False), ("", True)):
            with self.subTest(keymap=keymap), tempfile.TemporaryDirectory() as directory:
                target = self.target(directory)
                self.assertEqual(KEYBOARD.configure_keyboard(target, keymap), expected)
                self.assertEqual(
                    (target / "etc/vconsole.conf").read_text(),
                    "KEYMAP=us\nFONT=default8x16\n",
                )


if __name__ == "__main__":
    unittest.main()
