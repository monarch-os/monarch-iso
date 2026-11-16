import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SOURCE = Path(__file__).resolve().parents[2] / 'configs/airootfs/usr/share/monarch-iso'
sys.path.insert(0, str(SOURCE))
from orchestrator import luks_calibration as luks_format
from test.unit.test_luks_tuning import load_tuning


class LuksFormatTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))

    def device(self, size):
        path = self.root / str(size)
        with path.open('wb') as stream:
            stream.truncate(size)
        return str(path)

    def command(self, device):
        return ['cryptsetup', '--batch-mode', '--type', 'luks2', 'luksFormat', device]

    def test_aligned_and_partial_sector_devices(self):
        for size, sector in ((64 * 1024 * 1024, '4096'), (64 * 1024 * 1024 + 512, '512')):
            command = self.command(self.device(size))
            expected = command + ['--sector-size', sector] if sector == '4096' else command
            self.assertEqual(luks_format.format_command(command), expected)

    def test_probe_failures_leave_cryptsetup_defaults(self):
        for device in (str(self.root / 'missing'), self.device(0), self.device(513)):
            with self.subTest(device=device):
                command = self.command(device)
                self.assertEqual(luks_format.format_command(command), command)

    def test_existing_volumes_and_explicit_policies_are_untouched(self):
        commands = [
            ['cryptsetup', 'open', '/missing', 'root'],
            ['cryptsetup', 'luksAddKey', '/missing'],
            ['cryptsetup', 'reencrypt', '/missing'],
            ['cryptsetup', '--type', 'luks1', 'luksFormat', '/missing'],
            self.command('/missing') + ['--sector-size', '512'],
            self.command('/missing') + ['--sector-size=512'],
        ]
        for command in commands:
            self.assertEqual(luks_format.format_command(command), command)

    def test_free_space_entrypoint_preserves_stdin_key(self):
        device = self.device(64 * 1024 * 1024)
        with mock.patch.object(sys, 'argv', ['monarch-luks-calibrate', 'format', device]), \
                mock.patch.object(luks_format, 'stop_calibration'), \
                mock.patch.object(luks_format.os, 'execvp') as execute:
            luks_format.main()
        self.assertEqual(execute.call_args.args, ('cryptsetup', [
            'cryptsetup', 'luksFormat', device, '--sector-size', '4096',
            '--type', 'luks2', '--batch-mode', '--pbkdf', 'argon2id',
            '--key-size', '512', '--iter-time', '2000', '-',
        ]))

    def test_full_disk_policy_preserves_secrets_and_restores_runner_on_failure(self):
        runner = mock.Mock(side_effect=RuntimeError('format failed'))
        command = self.command(self.device(64 * 1024 * 1024))

        class Luks2:
            def encrypt(self):
                luks.run(command, input_data=b'test-only-passphrase')

        with load_tuning() as (tuning, luks, _), mock.patch.object(luks_format, 'stop_calibration') as stop:
            luks.run = runner
            wrapped = tuning._with_calibration(Luks2.encrypt)
            with self.assertRaisesRegex(RuntimeError, 'format failed'):
                wrapped(Luks2())
            runner.assert_called_once_with(command + ['--sector-size', '4096'], input_data=b'test-only-passphrase')
            self.assertIs(luks.run, runner)
            stop.assert_called_once()

    @unittest.skipUnless(shutil.which('cryptsetup'), 'cryptsetup unavailable')
    def test_real_luks_headers_and_passwords_for_both_sector_sizes(self):
        for size, sector in ((32 * 1024 * 1024, 4096), (32 * 1024 * 1024 + 512, 512)):
            with self.subTest(sector=sector):
                device = self.device(size)
                command = self.command(device) + ['--pbkdf', 'pbkdf2', '--pbkdf-force-iterations', '1000']
                subprocess.run(luks_format.format_command(command), input=b'test-only-passphrase',
                               check=True, capture_output=True)
                dump = subprocess.check_output(['cryptsetup', 'luksDump', '--dump-json-metadata', device])
                self.assertEqual(json.loads(dump)['segments']['0']['sector_size'], sector)
                subprocess.run(['cryptsetup', 'open', '--test-passphrase', device],
                               input=b'test-only-passphrase', check=True, capture_output=True)

    def test_boot_verifier_resolves_btrfs_subvolume_source(self):
        source = (SOURCE.parents[4] / 'bin/monarch-iso-test').read_text()
        function = source[source.index('verify_luks_sector_size() {'):source.index('\ninstall_phase() {')]
        script = r'''
set -euo pipefail
GUEST_PASSWORD=fixture
RUN_DIR=$1
sudo() { read -r password; shift 3; "$@"; }
findmnt() { [[ $* == '-nro SOURCE /' ]]; echo '/dev/mapper/root[/@]'; }
lsblk() {
  [[ $* == '-snrpo NAME,FSTYPE /dev/mapper/root' ]] || return 1
  printf '/dev/mapper/root btrfs\n/dev/vda2 crypto_LUKS\n/dev/vda\n'
}
cryptsetup() { [[ $* == 'luksDump /dev/vda2' ]]; echo 'sector: 4096'; }
export -f sudo findmnt lsblk cryptsetup
ssh_guest() { bash -eu -c "$1"; }
log() { :; }
'''
        subprocess.run(['bash', '-c', script + function + '\nverify_luks_sector_size',
                        'test', str(self.root)], check=True)


if __name__ == '__main__':
    unittest.main()
