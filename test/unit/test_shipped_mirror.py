import importlib.util
import io
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('select_shipped', ROOT / 'builder/select-shipped-mirror.py')
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)


class ShippedMirrorTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.image = self.root / 'image.packages'
        self.reachable = self.root / 'reachable'
        self.image.write_text('common 1-1\nchanged 1-1\n')
        self.filenames = {}
        with tarfile.open(self.root / 'offline.db.tar.gz', 'w:gz') as database:
            for name, version in [('common', '1-1'), ('changed', '2-1'), ('optional', '1-1'), ('live', '1-1')]:
                filename = f'{name}-{version}-any.pkg.tar.zst'
                self.filenames[name] = filename
                (self.root / filename).write_text(name)
                text = f'%NAME%\n{name}\n\n%VERSION%\n{version}\n\n%FILENAME%\n{filename}\n\n'.encode()
                entry = tarfile.TarInfo(f'{name}-{version}/desc')
                entry.size = len(text)
                database.addfile(entry, io.BytesIO(text))
        self.reachable.write_text('\n'.join(self.filenames[name] for name in ('common', 'changed', 'optional')))

    def test_same_version_removed_but_optional_and_changed_versions_remain(self):
        selected = selector.select(self.root, self.image, self.reachable)
        self.assertEqual(selected, sorted(self.filenames[name] for name in ('changed', 'optional')))
        airootfs = self.root / 'airootfs'
        metadata = airootfs / 'usr/share/monarch-iso'
        metadata.mkdir(parents=True)
        (metadata / 'offline-mirror.shipped').write_text('\n'.join(selected) + '\n')
        (self.root / 'offline.db').symlink_to('offline.db.tar.gz')
        (self.root / 'offline.files.tar.gz').write_text('file index')
        (self.root / 'offline.files').symlink_to('offline.files.tar.gz')
        (self.root / 'monarch-root.img.zst').write_text('root image')
        (self.root / 'monarch-root.img.zst.size').write_text('4096\n')
        subprocess.run(['bash', str(ROOT / 'builder/mirror-checksums.sh'), str(self.root), str(airootfs)],
                       check=True, capture_output=True)
        database = (self.root / 'offline.db.tar.gz').read_bytes()
        subprocess.run(['bash', str(ROOT / 'builder/prune-offline-mirror.sh'), str(self.root)],
                       input='\n'.join(selected) + '\n', text=True, check=True, capture_output=True)
        self.assertEqual((self.root / 'offline.db.tar.gz').read_bytes(), database)
        self.assertFalse((self.root / self.filenames['common']).exists())
        self.assertFalse((self.root / self.filenames['live']).exists())
        for filename in selected:
            self.assertTrue((self.root / filename).is_file())
        subprocess.run(['sha256sum', '--check', '--strict', str(metadata / 'offline-mirror.sha256')],
                       cwd=self.root, check=True, capture_output=True)

    def test_invalid_selection_fails_before_any_archive_is_removed(self):
        for bad in ('', 'not-in-the-mirror.pkg.tar.zst'):
            with self.subTest(bad=bad):
                self.reachable.write_text(bad)
                with self.assertRaises(ValueError):
                    selector.select(self.root, self.image, self.reachable)
                self.assertTrue(all((self.root / filename).exists() for filename in self.filenames.values()))

    def test_empty_image_index_and_missing_archive_fail(self):
        self.image.write_text('')
        with self.assertRaisesRegex(ValueError, 'Empty root image'):
            selector.select(self.root, self.image, self.reachable)
        self.image.write_text('common 1-1\n')
        (self.root / self.filenames['optional']).unlink()
        with self.assertRaisesRegex(ValueError, 'Missing mirror package'):
            selector.select(self.root, self.image, self.reachable)
