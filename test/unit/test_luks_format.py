import json
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

SOURCE = Path(__file__).resolve().parents[2] / 'configs/airootfs/usr/share/monarch-iso'
sys.path.insert(0, str(SOURCE))
from orchestrator import luks_format
from test.unit.test_installer_sanity_check import load_adapter


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
            self.assertEqual(luks_format.format_command(command), command + ['--sector-size', sector])

    def test_probe_failures_stop_before_formatting(self):
        for device in (str(self.root / 'missing'), self.device(0), self.device(513)):
            with self.subTest(device=device), self.assertRaises((OSError, ValueError)):
                luks_format.format_command(self.command(device))

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
        with mock.patch.object(sys, 'argv', ['luks_format.py', device]), \
                mock.patch.object(luks_format.os, 'execvp') as execute:
            luks_format.main()
        self.assertEqual(execute.call_args.args, ('cryptsetup', [
            'cryptsetup', 'luksFormat', device, '--sector-size', '4096',
            '--type', 'luks2', '--batch-mode', '-',
        ]))

    def test_full_disk_policy_preserves_secrets_and_restores_runner_on_failure(self):
        adapter = load_adapter()
        runner = mock.Mock(side_effect=RuntimeError('format failed'))
        luks = types.SimpleNamespace(run=runner)
        command = self.command(self.device(64 * 1024 * 1024))

        def filesystem_operations():
            luks.run(command, input_data=b'test-only-passphrase')

        handler = types.SimpleNamespace(perform_filesystem_operations=filesystem_operations)
        with mock.patch.dict(sys.modules, {'archinstall.lib.disk.luks': luks}), \
                mock.patch.object(adapter, 'FilesystemHandler', return_value=handler), \
                mock.patch.object(adapter, 'udev_sync'), \
                self.assertRaisesRegex(RuntimeError, 'format failed'):
            adapter.perform_filesystem_operations(types.SimpleNamespace(disk_config=object()))
        runner.assert_called_once_with(command + ['--sector-size', '4096'], input_data=b'test-only-passphrase')
        self.assertIs(luks.run, runner)

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
