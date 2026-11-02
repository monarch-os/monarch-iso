import json
import os
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

    def test_stalled_unmount_stops_without_retrying_or_writing(self):
        def stalled(command, **kwargs):
            self.assertGreater(kwargs['timeout'], 0)
            raise subprocess.TimeoutExpired(command, kwargs['timeout'], stderr=b'busy target')

        with mock.patch.object(root_image.subprocess, 'run', side_effect=stalled) as run, \
                mock.patch.object(root_image.time, 'sleep') as sleep:
            with self.assertRaises(subprocess.TimeoutExpired):
                root_image.unmount_tree(self.root)
            run.assert_called_once()
            sleep.assert_not_called()

    def test_uuid_refresh_bounds_each_external_call_and_checks_both_probes(self):
        def result(command, **kwargs):
            self.assertGreater(kwargs['timeout'], 0)
            output = 'fsid unique\n' if command[0] == 'btrfs' else 'unique\n'
            return subprocess.CompletedProcess(command, 0, output)

        with mock.patch.object(root_image.subprocess, 'run', side_effect=result) as run:
            root_image.refresh_uuid('/dev/test')
        probes = [call.args[0] for call in run.call_args_list if call.args[0][0] == 'blkid']
        self.assertEqual(len(probes), 2)
        self.assertIn('-p', probes[0])
        self.assertNotIn('-p', probes[1])

    @unittest.skipUnless(shutil.which('pacman'), 'pacman required')
    def test_package_delta_uses_real_pacman_versioned_provides(self):
        adapter = load_adapter()
        package = self.root / 'var/lib/pacman/local/replacement-1.0-1'
        package.mkdir(parents=True)
        (package.parent / 'ALPM_DB_VERSION').write_text(Path('/var/lib/pacman/local/ALPM_DB_VERSION').read_text())
        (package / 'desc').write_text('%NAME%\nreplacement\n\n%VERSION%\n1.0-1\n\n%PROVIDES%\noriginal=2.0\n\n')
        self.assertEqual(adapter.target_missing_packages(self.root, ['replacement', 'original>=2', 'original>=3', 'absent']),
                         ['original>=3', 'absent'])

    def test_application_delta_restores_method_after_failure(self):
        adapter = load_adapter()
        strap = mock.Mock(side_effect=RuntimeError('install failed'))
        installer = types.SimpleNamespace(target=self.root, add_additional_packages=strap)
        config = types.SimpleNamespace(app_config=True, auth_config=None)
        def install_apps(installer, config):
            installer.add_additional_packages(['present', 'missing'])
        handler = types.SimpleNamespace(install_applications=install_apps)
        with mock.patch.object(adapter, 'target_missing_packages', return_value=['missing']), \
                mock.patch.object(adapter, '_application_handler', return_value=handler):
            with self.assertRaisesRegex(RuntimeError, 'install failed'):
                adapter.install_applications(installer, config)
        self.assertIs(installer.add_additional_packages, strap)
        strap.assert_called_once_with(['missing'])

    def test_base_delta_configures_an_already_populated_root_without_pacstrap(self):
        adapter = load_adapter()
        part = types.SimpleNamespace(fs_type='btrfs')
        disk = types.SimpleNamespace(lvm_config=None, device_modifications=[types.SimpleNamespace(partitions=[part])])
        installer = mock.Mock(target=self.root, _disk_config=disk,
                              _disk_encryption=types.SimpleNamespace(partitions=[part]),
                              _base_packages=['base'], _helper_flags={}, _disable_fstrim=False,
                              _post_base_install_services=['NetworkManager'])
        callback = mock.Mock()
        installer.post_base_install = [callback]
        installer._get_microcode.return_value = Path('intel-ucode.img')
        installer.set_locale.return_value = True
        locale = types.SimpleNamespace(kb_layout='')
        config = types.SimpleNamespace(mirror_config=None, pacman_config=None)
        with mock.patch.object(adapter, 'PacmanConfig') as pacman, \
                mock.patch.object(adapter, 'target_missing_packages', return_value=[]):
            adapter.install_base_delta(installer, config, hostname='monarch', locale_config=locale)
        installer.pacman.strap.assert_not_called()
        installer._prepare_fs_type.assert_called_once_with('btrfs')
        installer._prepare_encrypt.assert_called_once_with()
        installer.set_vconsole.assert_called_once_with(locale)
        installer.set_hostname.assert_called_once_with('monarch')
        installer.set_locale.assert_called_once_with(locale)
        installer.enable_periodic_trim.assert_called_once_with()
        installer.enable_service.assert_called_once_with(['NetworkManager'])
        callback.assert_called_once_with(installer)
        pacman.return_value.persist.assert_called_once_with()
        self.assertEqual(installer._helper_flags, {'base-strapped': True, 'base': True})

    def test_subvolume_symlink_sources_and_parents_are_rejected_before_mutation(self):
        top = self.root / 'image'
        top.mkdir()
        external = self.root / 'external'
        external.mkdir()
        witness = external / 'keep'
        witness.write_text('preserve')
        for link in (str(external), '../external'):
            (top / 'link').symlink_to(link)
            for content, name in ((top / 'link', '@run'), (top / 'link/child', '@run'),
                                  (top, 'link/child')):
                with self.subTest(link=link, name=name), \
                        mock.patch.object(root_image.subprocess, 'run') as run:
                    with self.assertRaisesRegex(RuntimeError, 'Symlink-backed'):
                        root_image.create_subvolume(top, name, content)
                    run.assert_not_called()
                    self.assertEqual(witness.read_text(), 'preserve')
            (top / 'link').unlink()

    def test_encrypted_cmdline_serves_both_initramfs_flavours(self):
        original = 'root=/dev/mapper/root cryptdevice=UUID=abc:root:allow-discards,no-read-workqueue'
        cmdline = prebuilt_uki.with_sd_encrypt(original)
        self.assertIn(original, cmdline)
        self.assertIn('rd.luks.name=abc=root', cmdline)
        self.assertIn('rd.luks.options=abc=discard,no-read-workqueue', cmdline)
        self.assertEqual(prebuilt_uki.with_sd_encrypt(cmdline), cmdline)
        self.assertEqual(prebuilt_uki.with_sd_encrypt('root=UUID=abc'), 'root=UUID=abc')

    def test_archinstall_partuuid_is_resolved_to_the_luks_header_uuid(self):
        original = 'cryptdevice=PARTUUID=partition-id:root root=/dev/mapper/root'
        with mock.patch.object(prebuilt_uki.subprocess, 'run', return_value=
                               subprocess.CompletedProcess([], 0, 'luks-header-id\n')) as run:
            cmdline = prebuilt_uki.with_sd_encrypt(original)
        self.assertIn(original, cmdline)
        self.assertIn('rd.luks.name=luks-header-id=root', cmdline)
        self.assertNotIn('rd.luks.name=partition-id=', cmdline)
        self.assertIn('/dev/disk/by-partuuid/partition-id', run.call_args.args[0])
        self.assertGreater(run.call_args.kwargs['timeout'], 0)

    def test_unresolved_encrypted_partition_stops_before_generating_boot_parameters(self):
        with mock.patch.object(prebuilt_uki.subprocess, 'run', return_value=
                               subprocess.CompletedProcess([], 0, '')):
            with self.assertRaises(RuntimeError):
                prebuilt_uki.with_sd_encrypt('cryptdevice=PARTUUID=unknown:root')

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

    def test_built_uki_survives_default_console_configuration_and_deploys(self):
        kernel = self.root / 'usr/lib/modules/1.0/pkgbase'
        kernel.parent.mkdir(parents=True)
        kernel.write_text('linux-cachyos\n')
        (self.root / 'etc').mkdir()
        tools = self.root / 'tools'
        tools.mkdir()
        python = tools / 'python'
        python.write_text(f'#!/bin/bash\nexec {sys.executable} {SOURCE}/orchestrator/prebuilt_uki.py "${{@:2}}"\n')
        chroot = tools / 'arch-chroot'
        chroot.write_text('#!/bin/bash\nif [[ $2 == mkinitcpio ]]; then\n'
                          '  cp "$1/test.efi" "$1/var/lib/monarch-iso/prebuilt-uki.efi"\nfi\n')
        for tool in (python, chroot):
            tool.chmod(0o755)
        self.uki()
        subprocess.run(['bash', str(SOURCE.parents[4] / 'builder/prebuild-uki.sh'), str(self.root)],
                       env={**os.environ, 'PATH': f'{tools}:{os.environ["PATH"]}'}, check=True)
        (self.root / 'etc/vconsole.conf').write_text('KEYMAP=us\nFONT=default8x16\n')
        esp = self.root / 'boot'
        with mock.patch.object(prebuilt_uki.subprocess, 'run'):
            self.assertTrue(prebuilt_uki.deploy(self.root, esp, 'test', 'root=UUID=unique'))
        deployed = esp / 'EFI/Linux/test_linux-cachyos.efi'
        self.assertIn(b'root=UUID=unique', deployed.read_bytes())
        for config, text in [('etc/vconsole.conf', 'KEYMAP=fr\nFONT=default8x16\n'),
                             ('etc/monarch/provisioning.key', 'secret')]:
            (self.root / 'etc/vconsole.conf').write_text('KEYMAP=us\nFONT=default8x16\n')
            path = self.root / config
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            with mock.patch.object(prebuilt_uki.subprocess, 'run') as run:
                self.assertFalse(prebuilt_uki.deploy(self.root, esp, 'test', 'root=UUID=unique'))
                run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
