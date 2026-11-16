import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from contextlib import contextmanager
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'configs/airootfs/usr/share/monarch-iso'
sys.path.insert(0, str(SOURCE))


@contextmanager
def load_tuning():
    class Luks2:
        lock = mock.Mock()
        encrypt = mock.Mock()
        unlock = mock.Mock()

    class Installer:
        pass

    dependencies = {}
    def module(name, **values):
        obj = types.ModuleType(name)
        obj.__dict__.update(values)
        dependencies[name] = obj
        return obj

    module('archinstall')
    module('archinstall.lib')
    disk = module('archinstall.lib.disk')
    disk.luks = module('archinstall.lib.disk.luks', Luks2=Luks2, run=mock.Mock())
    module('archinstall.lib.command', run=mock.Mock(return_value=types.SimpleNamespace(stdout=b'')), SysCommand=mock.Mock())
    module('archinstall.lib.exceptions', DiskError=RuntimeError)
    module('archinstall.lib.log', debug=mock.Mock())
    module('archinstall.lib.installer', Installer=Installer)
    spec = importlib.util.spec_from_file_location('orchestrator._test_luks_tuning', SOURCE / 'orchestrator/luks_tuning.py')
    tuning = importlib.util.module_from_spec(spec)
    with mock.patch.dict(sys.modules, dependencies):
        spec.loader.exec_module(tuning)
        yield tuning, disk.luks, Installer


class LuksTuningTest(unittest.TestCase):
    def test_open_once_with_persistent_flags_and_original_key_transport(self):
        with load_tuning() as (tuning, _, _):
            volume = types.SimpleNamespace(luks_dev_path=Path('/dev/test'), mapper_name='root',
                                          is_unlocked=mock.Mock(side_effect=[False, True]),
                                          _get_passphrase_args=mock.Mock(return_value=(['--key-file', '/key'], None)))
            tuning._unlock(volume, Path('/key'))
            tuning.run.assert_called_once_with(['cryptsetup', 'open', '/dev/test', 'root',
                                               '--key-file', '/key', '--type', 'luks2',
                                               '--persistent', '--allow-discards', '--perf-no_read_workqueue'], input_data=None)
            tuning.run.reset_mock()
            volume.is_unlocked = mock.Mock(return_value=True)
            tuning._unlock(volume)
            tuning.run.assert_not_called()

    def test_open_errors_are_not_suppressed(self):
        with load_tuning() as (tuning, _, _):
            volume = types.SimpleNamespace(luks_dev_path='/dev/test', mapper_name='root',
                                          is_unlocked=lambda: False, _get_passphrase_args=lambda key: ([], b'fixture'))
            tuning.run.side_effect = subprocess.CalledProcessError(1, 'cryptsetup', output=b'open failed')
            with self.assertRaisesRegex(RuntimeError, 'open failed'):
                tuning._unlock(volume)

    def test_keep_open_and_escape_hatch(self):
        with load_tuning() as (tuning, _, _):
            volume = types.SimpleNamespace(mapper_name='root')
            with mock.patch.dict(os.environ, {'MONARCH_LUKS_KEEP_OPEN': '1'}):
                tuning._lock(volume)
                tuning._original_lock.assert_not_called()
            with mock.patch.dict(os.environ, {'MONARCH_LUKS_KEEP_OPEN': '0'}):
                tuning._lock(volume)
                tuning._original_lock.assert_called_once_with(volume)

    def test_apply_and_disable_match_upstream(self):
        with load_tuning() as (tuning, luks, installer):
            original = luks.Luks2.encrypt
            with mock.patch.dict(os.environ, {'MONARCH_LUKS_TUNING': '0'}):
                tuning.apply()
            self.assertIs(luks.Luks2.encrypt, original)
            with mock.patch.dict(os.environ, {'MONARCH_LUKS_TUNING': '1'}):
                tuning.apply()
            self.assertIs(luks.Luks2.unlock, tuning._unlock)
            self.assertIs(luks.Luks2.lock, tuning._lock)
            self.assertIs(installer._chroot_argv, tuning._chroot_argv)
            self.assertIs(installer.run_command, tuning._run_command)
            self.assertEqual(tuning._chroot_argv(types.SimpleNamespace(target='/mnt'), 'locale-gen'),
                             ['arch-chroot', '/mnt', 'locale-gen'])

    def test_locale_generation_skipped_only_when_all_requested_locales_exist(self):
        with load_tuning() as (tuning, _, _), tempfile.TemporaryDirectory() as temp:
            target = Path(temp)
            (target / 'etc').mkdir()
            locales = target / 'etc/locale.gen'
            locales.write_text('# comment\nen_US.UTF-8 UTF-8\nfr_FR.UTF-8 UTF-8\n')
            tuning.run.return_value.stdout = b'en_US.utf8 fr_FR.utf8'
            self.assertTrue(tuning._locale_archive_has_all(target))
            command = sys.modules['archinstall.lib.command'].SysCommand
            tuning._run_command(types.SimpleNamespace(target=target), 'locale-gen')
            command.assert_called_once_with('true')
            command.reset_mock()
            tuning.run.return_value.stdout = b'en_US.utf8'
            tuning._run_command(types.SimpleNamespace(target=target), 'locale-gen', True)
            command.assert_called_once_with(f'arch-chroot {target} locale-gen', peek_output=True)
            locales.unlink()
            self.assertFalse(tuning._locale_archive_has_all(target))

    def test_cmdline_options_support_both_hooks_and_are_idempotent(self):
        with load_tuning() as (tuning, _, _):
            original = 'quiet cryptdevice=UUID=fixture:root root=/dev/mapper/root'
            expected = ('quiet cryptdevice=UUID=fixture:root:allow-discards,no-read-workqueue root=/dev/mapper/root '
                        'rd.luks.name=fixture=root rd.luks.options=fixture=discard,no-read-workqueue')
            self.assertEqual(tuning.with_cmdline_options(original), expected)
            self.assertEqual(tuning.with_cmdline_options(expected), expected)
            self.assertEqual(tuning.with_cmdline_options('root=UUID=plain'), 'root=UUID=plain')
            with mock.patch.object(tuning.Path, 'exists', return_value=True):
                tuning.run.side_effect = subprocess.CalledProcessError(1, 'blkid')
                self.assertEqual(tuning._luks_uuid_of('UUID=fixture'), 'fixture')
