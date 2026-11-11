"""Regression checks for encrypted UKIs handed to the firmware."""

import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/monarch-iso"))
sys.modules["orchestrator.archinstall_adapter"] = types.ModuleType("orchestrator.archinstall_adapter")

from orchestrator import phases_impl  # noqa: E402


def reported_buildconfig():
    lines = ["# build configuration"] * 120
    lines[32] = "# HOOKS=(base)"
    lines[40] = "# HOOKS=(base systemd autodetect sd-encrypt filesystems fsck)"
    lines[54] = "HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck)"
    lines[81] = "HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck btrfs-overlayfs)"
    lines[117] = 'if [[ -n ${_monarch_hooks[*]} ]]; then'
    lines[118] = 'HOOKS=("${_monarch_hooks[@]}")'
    lines[119] = "fi"
    return "\n".join(lines) + "\n"


BUSYBOX_FILES = {"hooks/encrypt", "usr/bin/cryptsetup"}
SYSTEMD_FILES = {
    "init",
    "usr/lib/systemd/systemd",
    "usr/lib/systemd/system/initrd.target",
    "usr/lib/systemd/system/cryptsetup.target",
    "usr/lib/systemd/systemd-cryptsetup",
    "usr/lib/systemd/system-generators/systemd-cryptsetup-generator",
}


class EncryptedUkiArtifactTest(unittest.TestCase):
    def inspect(self, config, files):
        archive = "\n".join(sorted(files)) + "\n"

        def lsinitcpio(command, **kwargs):
            self.assertEqual(command[0], "lsinitcpio")
            self.assertNotIn("-a", command)
            return subprocess.CompletedProcess(command, 0, stdout=config if "-c" in command else archive)

        with mock.patch.object(phases_impl.subprocess, "run", side_effect=lsinitcpio) as run:
            phases_impl._validate_encrypted_uki(Path("monarch.efi"))
        return run

    def test_reported_multiassignment_buildconfig_does_not_hide_runtime_encrypt(self):
        self.inspect(reported_buildconfig(), BUSYBOX_FILES)

    def test_comments_or_assignments_never_substitute_for_runtime_hook(self):
        for config in ("# HOOKS=(base encrypt)", "HOOKS=(base encrypt)", reported_buildconfig()):
            with self.subTest(config=config), self.assertRaises(RuntimeError):
                self.inspect(config, {"usr/bin/cryptsetup"})

    def test_busybox_requires_both_components_and_normalizes_dot_prefixes(self):
        for missing in BUSYBOX_FILES:
            with self.subTest(missing=missing), self.assertRaises(RuntimeError):
                self.inspect("HOOKS=(base encrypt)", BUSYBOX_FILES - {missing})
        self.inspect("", {"./hooks/encrypt", "././usr/bin/cryptsetup"})

    def test_similar_names_directories_and_parent_paths_do_not_count(self):
        for files in ({"hooks/encrypt.disabled", "usr/bin/cryptsetup"},
                      {"hooks/encrypt/", "usr/bin/cryptsetup"},
                      {"hooks/encrypt", "usr/bin/cryptsetup/"},
                      {"../hooks/encrypt", "usr/bin/cryptsetup"}):
            with self.subTest(files=files), self.assertRaises(RuntimeError):
                self.inspect("HOOKS=(encrypt)", files)

    def test_systemd_chain_needs_no_fictitious_sd_encrypt_runtime_hook(self):
        self.inspect(reported_buildconfig(), SYSTEMD_FILES)
        self.inspect("", {"./" + path for path in SYSTEMD_FILES})

    def test_systemd_rejects_each_missing_runtime_component(self):
        for missing in SYSTEMD_FILES:
            with self.subTest(missing=missing), self.assertRaises(RuntimeError):
                self.inspect("HOOKS=(base systemd sd-encrypt)", SYSTEMD_FILES - {missing})

    def test_never_analyzes_or_reads_raw_buildconfig(self):
        run = self.inspect("touch /never-execute-image-content", BUSYBOX_FILES)
        self.assertEqual([call.args[0] for call in run.call_args_list], [["lsinitcpio", "monarch.efi"]])

    def test_inspection_failure_still_stops_validation(self):
        for failure in (subprocess.CalledProcessError(1, ["lsinitcpio"], stderr="damaged archive"),
                        OSError("lsinitcpio unavailable")):
            with self.subTest(failure=failure), mock.patch.object(phases_impl.subprocess, "run", side_effect=failure):
                with self.assertRaisesRegex(RuntimeError, "Could not inspect encrypted UKI"):
                    phases_impl._validate_encrypted_uki(Path("monarch.efi"))

    @unittest.skipUnless(shutil.which("lsinitcpio") and shutil.which("bsdtar"), "mkinitcpio tools required")
    def test_real_cpio_with_reported_buildconfig_and_inert_runtime_config(self):
        with tempfile.TemporaryDirectory(prefix="encrypted-uki-") as tmp:
            root = Path(tmp)
            payload = root / "payload"
            payload.mkdir()
            marker = root / "must-not-exist"
            content = {"buildconfig": reported_buildconfig(),
                       "config": f'HOOKS="encrypt"\ntouch "{marker}"\n',
                       "init": "#!/usr/bin/ash\n. /config\n",
                       "hooks/encrypt": "run_hook() { :; }\n",
                       "usr/bin/cryptsetup": "fixture binary\n"}
            for name, text in content.items():
                path = payload / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            image = root / "initramfs.img"
            subprocess.run(["bsdtar", "--format", "newc", "-cf", str(image), "-C", str(payload), *content],
                           check=True, capture_output=True, timeout=10)
            raw = subprocess.run(["lsinitcpio", "-c", str(image)],
                                 check=True, capture_output=True, text=True, timeout=10).stdout
            self.assertEqual(raw, reported_buildconfig())
            phases_impl._validate_encrypted_uki(image)
            self.assertFalse(marker.exists())
            content.pop("hooks/encrypt")
            subprocess.run(["bsdtar", "--format", "newc", "-cf", str(image), "-C", str(payload), *content],
                           check=True, capture_output=True, timeout=10)
            with self.assertRaisesRegex(RuntimeError, "cannot unlock an encrypted root"):
                phases_impl._validate_encrypted_uki(image)
            self.assertFalse(marker.exists())


class EncryptedUkiValidationTest(unittest.TestCase):
    def test_rejects_the_broken_installed_uki_pattern(self):
        archive = "usr/bin/fsck\nusr/bin/systemd\n"

        with self.assertRaisesRegex(RuntimeError, "cannot unlock an encrypted root"):
            phases_impl._assert_encrypted_uki_contents("monarch.efi", archive)

    def test_accepts_busybox_encrypt_and_cryptsetup(self):
        archive = "usr/bin/cryptsetup\nhooks/encrypt\n"

        phases_impl._assert_encrypted_uki_contents("monarch.efi", archive)

    def test_accepts_systemd_sd_encrypt_and_its_unlock_binary(self):
        archive = "\n".join(sorted(SYSTEMD_FILES))

        phases_impl._assert_encrypted_uki_contents("monarch.efi", archive)

    def test_rejects_missing_or_mismatched_unlock_components(self):
        generator = 'usr/lib/systemd/system-generators/systemd-cryptsetup-generator\n'
        for archive in (
            generator,
            'usr/lib/systemd/systemd-cryptsetup\n',
            'usr/bin/cryptsetup\n' + generator,
            'usr/lib/systemd/systemd-cryptsetup\n' + generator,
        ):
            with self.subTest(archive=archive), self.assertRaises(RuntimeError):
                phases_impl._assert_encrypted_uki_contents('monarch.efi', archive)


if __name__ == "__main__":
    unittest.main()
