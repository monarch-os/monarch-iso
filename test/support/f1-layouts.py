"""Run inside a disposable integration guest against the ISO's actual root image."""

import subprocess
import tempfile
from pathlib import Path
from types import SimpleNamespace

from orchestrator import root_image


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=120).stdout.strip()


def exercise(work, protected, layout):
    backing = work / 'root.btrfs'
    run('truncate', '-s', '12G', str(backing))
    device = run('losetup', '--find', '--show', str(backing))
    target = work / 'target'
    target.mkdir()
    top = work / 'top'
    top.mkdir()
    ctx = SimpleNamespace(target=target, state_dir=work / 'state', is_protected=protected)
    ctx.state_dir.mkdir()
    try:
        run('mkfs.btrfs', '-f', device)
        original_uuid = run('blkid', '-p', '-s', 'UUID', '-o', 'value', device)
        run('mount', device, str(top))
        for name, _ in layout:
            run('btrfs', 'subvolume', 'create', str(top / name))
        run('umount', str(top))
        for name, path in layout:
            mount = target / path
            mount.mkdir(parents=True, exist_ok=True)
            run('mount', '-o', f'subvol={name}', device, str(mount))

        root_image.install(ctx)
        assert run('blkid', '-p', '-s', 'UUID', '-o', 'value', device) != original_uuid
        assert (target / 'etc/machine-id').read_text().strip()
        assert (target / 'usr/bin/pacman').is_file()
        assert (target / 'var/lib/pacman/local/ALPM_DB_VERSION').is_file()
        for name, path in layout:
            actual = run('findmnt', '-n', '-o', 'FSROOT', '--mountpoint', str(target / path))
            assert actual == '/' + name, (name, path, actual)
        print(f'PASS protected={protected}: {layout}', flush=True)
    finally:
        for mount in (ctx.state_dir / 'image-top', target, top):
            subprocess.run(['umount', '-R', str(mount)], capture_output=True, timeout=30)
        run('losetup', '-d', device)


root_image.IMAGE = Path('/run/f1-media/arch/x86_64/monarch-root.img.zst')
layouts = [
    (True, [('@', '.'), ('@home', 'home'), ('@log', 'var/log'), ('@pkg', 'var/cache/pacman/pkg')]),
    (False, [('@', '.'), ('@home', 'home'), ('@var', 'var'), ('@var/lib', 'var/lib'),
             ('@pkg', 'var/cache/pacman/pkg')]),
]
for protected, layout in layouts:
    with tempfile.TemporaryDirectory(prefix='f1-layout-', dir='/var/tmp') as directory:
        exercise(Path(directory), protected, layout)
