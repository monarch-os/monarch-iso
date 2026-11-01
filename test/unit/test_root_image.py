import json
import shutil
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

SOURCE = Path(__file__).resolve().parents[2] / 'configs/airootfs/usr/share/monarch-iso'
sys.path.insert(0, str(SOURCE))
from orchestrator import root_image, prebuilt_uki
from test.unit.test_installer_sanity_check import load_adapter


class RootImageTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def test_protected_root_rejects_hidden_home_data_and_foreign_subvolumes(self):
        for name in root_image.STANDARD_SUBVOLUMES:
            (self.root / name).mkdir()
        root_image.assert_empty(self.root, root_image.STANDARD_SUBVOLUMES)
        file = self.root / '@home/precious'
        file.write_text('keep')
        with self.assertRaisesRegex(RuntimeError, 'already contains files'):
            root_image.assert_empty(self.root, root_image.STANDARD_SUBVOLUMES)
        file.unlink()
        (self.root / '@snapshots').mkdir()
        with self.assertRaisesRegex(RuntimeError, 'already contains @snapshots'):
            root_image.assert_empty(self.root, root_image.STANDARD_SUBVOLUMES)

    def test_nested_subvolumes_must_follow_their_mounts(self):
        base = [{'name': '@', 'mountpoint': '/'}]
        root_image.validate_subvolumes(base + [{'name': '@var', 'mountpoint': '/var'},
                                              {'name': '@var/lib', 'mountpoint': '/var/lib'}])
        for extra in ([{'name': '@/usr', 'mountpoint': '/opt'}],
                      [{'name': '../outside', 'mountpoint': '/opt'}],
                      [{'name': '@var', 'mountpoint': '/var'}, {'name': '@/var/lib', 'mountpoint': '/var/lib'}]):
            with self.subTest(extra=extra), self.assertRaises(RuntimeError):
                root_image.validate_subvolumes(base + extra)

    def test_fat_staging_follows_links_before_sources_are_removed(self):
        boot = self.root / 'boot'
        boot.mkdir()
        (boot / 'kernel').write_text('kernel')
        (boot / 'current').symlink_to('kernel')
        nested = boot / 'efi'
        nested.mkdir()
        (nested / 'foreign').write_text('preserve')
        stage = self.root / 'stage'
        root_image.copy_fat_tree(boot, stage, {Path('efi')})
        root_image.remove_fat_tree(boot, {Path('efi')})
        self.assertEqual((stage / 'current').read_text(), 'kernel')
        self.assertFalse((stage / 'current').is_symlink())
        self.assertEqual((nested / 'foreign').read_text(), 'preserve')
        self.assertFalse((stage / 'efi').exists())

    def test_small_target_is_rejected_before_unmount_or_write(self):
        ctx = types.SimpleNamespace(target=self.root)
        with mock.patch.object(root_image, 'target_layout', return_value=([], '/dev/test', [])), \
                mock.patch.object(root_image, 'image_size', return_value=8192), \
                mock.patch.object(root_image.subprocess, 'run', side_effect=[
                    subprocess.CompletedProcess([], 0, 'Total devices 1 FS bytes used 0'),
                    subprocess.CompletedProcess([], 0, '4096')]), \
                mock.patch.object(root_image, 'write_image') as write, \
                mock.patch.object(root_image, 'unmount_tree') as unmount:
            with self.assertRaisesRegex(RuntimeError, 'too small'):
                root_image.install(ctx)
        write.assert_not_called()
        unmount.assert_not_called()

    @unittest.skipUnless(shutil.which('pacman'), 'pacman required')
    def test_package_delta_uses_real_pacman_versioned_provides(self):
        adapter = load_adapter()
        package = self.root / 'var/lib/pacman/local/replacement-1.0-1'
        package.mkdir(parents=True)
        (package.parent / 'ALPM_DB_VERSION').write_text(Path('/var/lib/pacman/local/ALPM_DB_VERSION').read_text())
        (package / 'desc').write_text('%NAME%\nreplacement\n\n%VERSION%\n1.0-1\n\n%PROVIDES%\noriginal=2.0\n\n')
        self.assertEqual(adapter.target_missing_packages(self.root, ['replacement', 'original>=2', 'original>=3', 'absent']),
                         ['original>=3', 'absent'])

    def test_delta_restores_pacstrap_after_failure(self):
        adapter = load_adapter()
        strap = mock.Mock(side_effect=RuntimeError('install failed'))
        installer = types.SimpleNamespace(target=self.root, pacman=types.SimpleNamespace(strap=strap))
        with mock.patch.object(adapter, 'target_missing_packages', return_value=['missing']):
            with self.assertRaisesRegex(RuntimeError, 'install failed'):
                with adapter.installed_package_delta(installer):
                    installer.pacman.strap(['present', 'missing'])
        self.assertIs(installer.pacman.strap, strap)
        strap.assert_called_once_with(['missing'])

    @unittest.skipUnless(shutil.which('zstd'), 'zstd required')
    def test_decoder_failure_is_not_hidden_by_a_successful_writer(self):
        source = self.root / 'payload'
        source.write_bytes(b'nonzero block' * 1024)
        image = self.root / 'image.zst'
        subprocess.run(['zstd', '-q', str(source), '-o', str(image)], check=True)
        image.write_bytes(image.read_bytes()[:-8])
        # The writer consumes the stream successfully even if decoding ends early.
        original = subprocess.Popen
        with mock.patch.object(root_image, 'IMAGE', image), \
                mock.patch.object(root_image.subprocess, 'Popen', wraps=subprocess.Popen) as popen:
            def launch(command, **kwargs):
                if command[0] == 'dd':
                    command = ['cat']
                    kwargs['stdout'] = subprocess.DEVNULL
                return original(command, **kwargs)

            popen.side_effect = launch
            with self.assertRaisesRegex(RuntimeError, 'Root image write failed'):
                root_image.write_image('/unused')

    def uki(self):
        data = bytearray(4096)
        data[:2] = b'MZ'
        struct.pack_into('<I', data, 60, 128)
        data[128:132] = b'PE\0\0'
        struct.pack_into('<H', data, 134, 1)
        data[152:160] = b'.cmdline'
        struct.pack_into('<IIII', data, 160, 1800, 0, 2048, 2048)
        data[2048:3848] = b'monarch.cmdline_room='.ljust(1800, b'0')
        uki = self.root / 'test.efi'
        uki.write_bytes(data)
        return uki

    def test_uki_cmdline_is_embedded_without_moving_other_bytes(self):
        uki = self.uki()
        before = uki.read_bytes()
        self.assertTrue(prebuilt_uki.embed_cmdline(uki, 'root=UUID=unique cryptdevice=UUID=luks:root'))
        after = uki.read_bytes()
        self.assertEqual(before[:2048], after[:2048])
        self.assertEqual(before[3848:], after[3848:])
        self.assertIn(b'root=UUID=unique', after)
        self.assertEqual(after[3847], 0)

    def test_bad_or_oversized_uki_cmdline_leaves_image_untouched(self):
        uki = self.uki()
        before = uki.read_bytes()
        self.assertFalse(prebuilt_uki.embed_cmdline(uki, 'x' * 1800))
        self.assertEqual(before, uki.read_bytes())
        uki.write_bytes(b'broken')
        self.assertFalse(prebuilt_uki.embed_cmdline(uki, 'root=UUID=test'))
        self.assertEqual(uki.read_bytes(), b'broken')

    def test_keyboard_hardware_and_microcode_changes_invalidate_uki(self):
        baseline = prebuilt_uki.fingerprint(self.root)
        for file, contents in [('etc/vconsole.conf', 'KEYMAP=fr\n'),
                               ('etc/mkinitcpio.conf.d/nvidia.conf', 'MODULES+=(nvidia)\n'),
                               ('etc/modprobe.d/blacklist.conf', 'blacklist nouveau\n'),
                               ('usr/lib/firmware/intel-ucode/new', 'microcode')]:
            with self.subTest(file=file):
                path = self.root / file
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents)
                self.assertNotEqual(prebuilt_uki.fingerprint(self.root), baseline)
                path.unlink()


if __name__ == '__main__':
    unittest.main()
