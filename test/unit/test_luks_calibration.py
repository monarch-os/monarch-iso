"""Boot calibration is optional; invalid data must never force a weaker cost."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'configs/airootfs/usr/share/monarch-iso'))
from orchestrator import luks_calibration as luks

LINE = 'argon2id     13 iterations, 1048576 memory, 4 parallel threads (CPUs) for 512-bit key (requested 2000 ms time)'
COMMAND = ['cryptsetup', '--batch-mode', '--verbose', '--type', 'luks2', '--pbkdf', 'argon2id', '--hash', 'sha512', '--key-size', '512', '--iter-time', '2000', '--use-urandom', 'luksFormat', '/dev/missing-calibration-fixture']


class Calibration(unittest.TestCase):
    def setUp(self):
        self.directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.path = self.directory / 'result.json'
        self.enterContext(mock.patch.object(luks, 'STATE', self.path))
        self.enterContext(mock.patch.object(luks, 'memory_total', return_value=8*1024*1024))
        self.enterContext(mock.patch.object(luks, 'memory_available', return_value=4*1024*1024))
        self.enterContext(mock.patch.object(luks.os, 'cpu_count', return_value=4))
        self.data = dict(schema=1, iter_time=2000, key_size=512, cpus=4,
                         iterations=13, memory=1048576, parallel=4)
        fstat = os.fstat
        def root_stat(fd):
            st = fstat(fd)
            return types.SimpleNamespace(st_uid=0, st_mode=st.st_mode, st_size=st.st_size)
        self.enterContext(mock.patch.object(luks.os, 'fstat', side_effect=root_stat))

    def write(self, data=None):
        self.path.write_text(json.dumps(self.data if data is None else data))
        self.path.chmod(0o600)

    def test_parser_and_policy(self):
        self.assertEqual(luks.parse_benchmark('# header\n'+LINE+'\n'),
                         dict(iterations=13, memory=1048576, parallel=4))
        for output in ('', LINE+'\n'+LINE, LINE.replace('argon2id', 'argon2i'),
                       LINE.replace('2000 ms', '1000 ms'), LINE.replace('512-bit', '256-bit'),
                       LINE.replace('13 iterations', '3 iterations'), LINE+' garbage'):
            with self.subTest(output=output), self.assertRaises(ValueError):
                luks.parse_benchmark(output)

    def test_complete_result_replaces_time_with_costs_only(self):
        self.write()
        changed = luks.format_command(COMMAND)
        self.assertEqual(changed, COMMAND[:11] + ['--pbkdf-force-iterations', '13',
                         '--pbkdf-memory', '1048576', '--pbkdf-parallel', '4'] + COMMAND[13:])
        self.assertIn('--iter-time', COMMAND)

    def test_absent_malformed_and_invalid_cache_fall_back(self):
        self.assertEqual(luks.format_command(COMMAND), COMMAND)
        for text in ('{partial', '[]', 'null', '0', 'x'*5000):
            self.path.write_text(text)
            self.path.chmod(0o600)
            self.assertEqual(luks.format_command(COMMAND), COMMAND)
        for key, value in [('schema', 2), ('iter_time', 1000), ('key_size', 256), ('cpus', 2),
                           ('iterations', 3), ('iterations', 2**32), ('iterations', True),
                           ('iterations', '13'), ('memory', 65535), ('memory', 1048577),
                           ('memory', 96082), ('parallel', 0), ('parallel', 5)]:
            self.write({**self.data, key: value})
            self.assertEqual(luks.format_command(COMMAND), COMMAND)

    def test_untrusted_permissions_symlink_fifo_and_owner_are_rejected(self):
        self.write()
        self.path.chmod(0o666)
        self.assertEqual(luks.cached_options(2000, 512), [])
        self.path.rename(self.directory / 'other')
        self.path.symlink_to(self.directory / 'other')
        self.assertEqual(luks.cached_options(2000, 512), [])
        self.path.unlink()
        os.mkfifo(self.path)
        self.assertEqual(luks.cached_options(2000, 512), [])
        self.path.unlink()
        self.write()
        with mock.patch.object(luks.os, 'fstat', return_value=types.SimpleNamespace(st_uid=1000, st_mode=0o100600, st_size=200)):
            self.assertEqual(luks.cached_options(2000, 512), [])

    def test_memory_and_custom_policy_fall_back(self):
        self.write()
        for field, value in [('memory_total', 4*1024*1024-65536), ('memory_available', 1024*1024)]:
            with mock.patch.object(luks, field, return_value=value):
                self.assertEqual(luks.format_command(COMMAND), COMMAND)
        for old, new in [('2000', '10000'), ('512', '256'), ('luks2', 'luks1'),
                         ('argon2id', 'pbkdf2'), ('luksFormat', 'open')]:
            command = [new if x == old else x for x in COMMAND]
            self.assertEqual(luks.format_command(command), command)
        for extra in (['--pbkdf-memory', '524288'], ['--pbkdf-force-iterations', '9'],
                      ['--pbkdf-parallel', '2'], ['--iter-time', '2000']):
            self.assertEqual(luks.format_command(COMMAND + extra), COMMAND + extra)

    def test_producer_publishes_complete_private_result(self):
        with mock.patch.object(luks.subprocess, 'run', return_value=types.SimpleNamespace(stdout=LINE)) as run:
            luks.calibrate()
        self.assertEqual(json.loads(self.path.read_text()), self.data)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.directory.glob('.result-*')), [])
        self.assertEqual(run.call_args.kwargs['env']['LC_ALL'], 'C')
        self.assertNotIn('luksFormat', run.call_args.args[0])

    def test_failed_or_skipped_calibration_removes_stale_result(self):
        self.write()
        with mock.patch.object(luks.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'cryptsetup')):
            with self.assertRaises(subprocess.CalledProcessError):
                luks.calibrate()
        self.assertFalse(self.path.exists())
        for field, value in [('memory_total', 4*1024*1024-65536), ('memory_available', 512*1024)]:
            self.write()
            with mock.patch.object(luks, field, return_value=value), mock.patch.object(luks.subprocess, 'run') as run:
                luks.calibrate()
                run.assert_not_called()
            self.assertFalse(self.path.exists())
        self.write()
        with mock.patch.object(luks.subprocess, 'run', return_value=types.SimpleNamespace(stdout=LINE.replace('1048576 memory', '96082 memory'))):
            luks.calibrate()
        self.assertFalse(self.path.exists())

    def test_stop_failure_does_not_block_normal_format(self):
        for failure in (OSError(), subprocess.TimeoutExpired('systemctl', 10)):
            with mock.patch.object(luks.subprocess, 'run', side_effect=failure):
                luks.stop_calibration()

    def test_live_service_wiring(self):
        system = ROOT / 'configs/airootfs/etc/systemd/system'
        link = system / 'multi-user.target.wants/monarch-luks-calibrate.service'
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.resolve(), system / 'monarch-luks-calibrate.service')
        service = link.read_text()
        for setting in ('PrivateDevices=yes', 'RuntimeDirectoryPreserve=yes', 'RuntimeDirectoryMode=0700',
                        'UMask=0077', 'TimeoutStopSec=2', 'After=monarch-mirror-verify.service monarch-root-image-verify.service'):
            self.assertIn(setting, service)
