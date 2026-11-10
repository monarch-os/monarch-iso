import importlib.util
import io
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ship_sync', REPO / 'builder/ship-sync-databases.py')
ship_sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ship_sync)


class ShipSyncDatabasesTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='sync-indexes-')
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.root = self.work / 'root'
        self.runtime = self.root / 'usr/share/monarch'
        self.config = self.runtime / 'default/pacman/pacman.conf'
        self.config.parent.mkdir(parents=True)
        self.config.write_text((REPO / 'configs/pacman-online.conf').read_text())
        mirrorlist = self.root / 'etc/pacman.d/mirrorlist'
        mirrorlist.parent.mkdir(parents=True)
        mirrorlist.write_text('Server = https://mirror.invalid/$repo/os/$arch\n')
        self.source = self.work / 'sync'
        self.source.mkdir()
        self.destination = self.root / 'var/lib/pacman/sync'
        self.destination.mkdir(parents=True)
        self.offline = self.destination / 'offline.db'
        self.offline.write_bytes(b'offline installer database')
        self.databases('cachyos', 'core', 'extra', 'multilib', 'monarch', 'platform', 'aur')

    def databases(self, *repos):
        for repo in repos:
            path = self.source / f'{repo}.db'
            path.write_bytes(repo.encode())
            os.utime(path, ns=(1700000000123456789, 1700000000123456789))

    def ship(self):
        ship_sync.ship(self.root, self.source)

    def test_image_builder_requires_sync_handoff_before_privileged_operations(self):
        environment = dict(os.environ)
        environment.pop('MONARCH_IMAGE_SYNC_DBS', None)
        result = subprocess.run(['bash', str(REPO / 'builder/build-root-image.sh'),
                                 'unused.conf', 'unused-output', 'fixture-package'],
                                env=environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn("requires the build's online sync directory", result.stderr)

    def test_exact_runtime_databases_contents_mtimes_and_offline_preserved(self):
        offline_before = self.offline.stat()
        self.ship()
        self.assertEqual({p.stem for p in self.destination.iterdir()},
                         {'offline', 'cachyos', 'core', 'extra', 'multilib', 'monarch'})
        for repo in ('cachyos', 'core', 'extra', 'multilib', 'monarch'):
            source, target = self.source / f'{repo}.db', self.destination / f'{repo}.db'
            self.assertEqual(target.read_bytes(), source.read_bytes())
            self.assertEqual(target.stat().st_mtime_ns, source.stat().st_mtime_ns)
        self.assertEqual(self.offline.read_bytes(), b'offline installer database')
        self.assertEqual(self.offline.stat().st_mtime_ns, offline_before.st_mtime_ns)
        self.ship()

    def test_every_configured_database_required_even_with_stale_destination(self):
        for repo in ('cachyos', 'core', 'extra', 'multilib', 'monarch'):
            with self.subTest(repo=repo):
                database = self.source / f'{repo}.db'
                content = database.read_bytes()
                database.unlink()
                (self.destination / database.name).write_bytes(b'stale')
                with self.assertRaisesRegex(RuntimeError, f'Missing runtime database: .*{repo}.db'):
                    self.ship()
                database.write_bytes(content)

    def test_nested_glob_includes_custom_repositories_and_comments(self):
        included = self.root / 'etc/pacman.d/repos'
        included.mkdir()
        (included / 'custom.conf').write_text(' [custom-repo] # enabled\nInclude = /etc/pacman.d/servers\n')
        (self.root / 'etc/pacman.d/servers').write_text('Server = https://custom.invalid/$repo\n')
        with self.config.open('a') as stream:
            stream.write('\nInclude = /etc/pacman.d/repos/*.conf\n')
        with self.assertRaisesRegex(RuntimeError, 'custom-repo.db'):
            self.ship()
        self.databases('custom-repo')
        self.ship()
        self.assertEqual((self.destination / 'custom-repo.db').read_bytes(), b'custom-repo')

    def test_hardware_repository_optional_and_script_never_executed(self):
        hardware = self.runtime / 'install/hardware/pacman.sh'
        hardware.parent.mkdir(parents=True)
        hardware.write_text('exit 99\ncat <<EOF\n[arch-mact2]\nServer = unused\nEOF\n')
        self.ship()
        self.assertFalse((self.destination / 'arch-mact2.db').exists())
        self.databases('arch-mact2')
        self.ship()
        self.assertTrue((self.destination / 'arch-mact2.db').is_file())

    def test_missing_configuration_or_empty_repository_selection_fails(self):
        self.config.unlink()
        with self.assertRaises(OSError):
            self.ship()
        for content in ('[options]\n', '[offline]\n', '[../outside]\n'):
            with self.subTest(content=content):
                self.config.write_text(content)
                with self.assertRaises(RuntimeError):
                    self.ship()

    def test_invalid_includes_fail_without_reading_host_files(self):
        for include in ('/missing/*.conf', 'relative.conf', '/../../etc/passwd'):
            with self.subTest(include=include):
                self.config.write_text(f'[core]\nInclude = {include}\n')
                with self.assertRaises(RuntimeError):
                    self.ship()
        self.config.write_text('Include = /usr/share/monarch/default/pacman/pacman.conf\n')
        with self.assertRaisesRegex(RuntimeError, 'Recursive'):
            self.ship()
        external = self.work / 'external.conf'
        external.write_text('[external]\n')
        (self.root / 'escape').symlink_to(external)
        self.config.write_text('Include = /escape\n')
        with self.assertRaisesRegex(RuntimeError, 'escapes image'):
            self.ship()

    def test_destination_symlink_does_not_overwrite_external_file(self):
        external = self.work / 'precious'
        external.write_bytes(b'preserve')
        (self.destination / 'core.db').symlink_to(external)
        with self.assertRaisesRegex(RuntimeError, 'Symlink-backed'):
            self.ship()
        self.assertEqual(external.read_bytes(), b'preserve')

    @unittest.skipUnless(shutil.which('pacman'), 'pacman required')
    def test_real_pacman_print_resolves_shipped_index_without_synchronization(self):
        self.config.write_text('[options]\nArchitecture = x86_64\nSigLevel = Never\n[custom]\nServer = https://unused.invalid\n')
        data = b'%NAME%\nfixture-package\n\n%VERSION%\n1-1\n\n%FILENAME%\nfixture-package-1-1-any.pkg.tar.zst\n\n%ARCH%\nany\n\n'
        with tarfile.open(self.source / 'custom.db', 'w:gz') as archive:
            entry = tarfile.TarInfo('fixture-package-1-1/desc')
            entry.size = len(data)
            archive.addfile(entry, io.BytesIO(data))
        self.ship()
        result = subprocess.run(['pacman', '--config', str(self.config), '--dbpath', str(self.destination.parent),
                                 '-S', '--print', '--print-format', '%n %v', 'fixture-package'],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'fixture-package 1-1')

    def test_image_payload_indexes_covered_by_existing_integrity_manifest(self):
        self.ship()
        image_dir = self.work / 'image'
        image_dir.mkdir()
        image = image_dir / 'monarch-root.img.zst'
        # A tar fixture stands in for Btrfs: no mount, loop device or disk write.
        with tarfile.open(image, 'w') as archive:
            archive.add(self.root, arcname='.')
        with tarfile.open(image) as archive:
            self.assertEqual(archive.extractfile('./var/lib/pacman/sync/cachyos.db').read(), b'cachyos')
        (image_dir / 'monarch-root.img.zst.size').write_text(str(image.stat().st_size))
        mirror = self.work / 'mirror'
        mirror.mkdir()
        for name in ('fixture.pkg.tar.zst', 'offline.db', 'offline.db.tar.gz', 'offline.files', 'offline.files.tar.gz'):
            (mirror / name).write_text('fixture')
        live = self.work / 'live'
        metadata = live / 'usr/share/monarch-iso'
        metadata.mkdir(parents=True)
        (metadata / 'root-image.path').write_text('/run/archiso/bootmnt/arch/x86_64/monarch-root.img.zst\n')
        subprocess.run(['bash', str(REPO / 'builder/mirror-checksums.sh'), str(mirror), str(live), str(image_dir)],
                       check=True, capture_output=True, timeout=10)
        manifest = metadata / 'offline-mirror.sha256'
        manifest.write_text(manifest.read_text().replace('/run/archiso/bootmnt/arch/x86_64', str(image_dir)))
        def verify():
            return subprocess.run(['sha256sum', '--check', str(manifest)], cwd=mirror,
                                  capture_output=True, timeout=10)
        self.assertEqual(verify().returncode, 0)
        with image.open('ab') as stream:
            stream.write(b'corrupt index payload')
        self.assertNotEqual(verify().returncode, 0)


if __name__ == '__main__':
    unittest.main()
