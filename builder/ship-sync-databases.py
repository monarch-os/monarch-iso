#!/usr/bin/python3
import glob
import re
import shutil
import sys
from pathlib import Path


SECTION = re.compile(r'\[([^\]]+)\]')


def confined(root, path):
    if not path.resolve().is_relative_to(root):
        raise RuntimeError(f'Pacman path escapes image: {path}')
    return path


def repositories(root, config, stack=()):
    config = confined(root, config)
    resolved = config.resolve()
    if resolved in stack or len(stack) >= 32:
        raise RuntimeError(f'Recursive pacman Include: {config}')
    repos = set()
    for line in config.read_text().splitlines():
        line = line.split('#', 1)[0].strip()
        section = SECTION.fullmatch(line)
        if section:
            name = section[1]
            if name != 'options':
                if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]*', name):
                    raise RuntimeError(f'Invalid pacman repository: {name}')
                repos.add(name)
        elif re.match(r'Include\s*=', line):
            pattern = line.split('=', 1)[1].strip()
            if not pattern.startswith('/'):
                raise RuntimeError(f'Pacman Include must be image-absolute: {pattern}')
            matches = sorted(glob.glob(str(root / pattern.lstrip('/'))))
            if not matches:
                raise RuntimeError(f'Missing pacman Include: {pattern}')
            for match in matches:
                repos.update(repositories(root, Path(match), (*stack, resolved)))
    return repos


def ship(root, source):
    root = root.resolve()
    runtime = root / 'usr/share/monarch'
    required = repositories(root, runtime / 'default/pacman/pacman.conf')
    if not required or 'offline' in required:
        raise RuntimeError('No online runtime repositories configured')
    optional = set()
    hardware = runtime / 'install/hardware/pacman.sh'
    if hardware.exists():
        # Read literal repository declarations, never execute hardware detection.
        optional = set(re.findall(r'^\[([A-Za-z0-9_][A-Za-z0-9_.-]*)\]\s*$',
                                  hardware.read_text(), re.MULTILINE)) - {'options', 'offline'}
    for repo in sorted(required):
        if not (source / f'{repo}.db').is_file():
            raise RuntimeError(f'Missing runtime database: {source / (repo + ".db")}')
    destination = confined(root, root / 'var/lib/pacman/sync')
    destination.mkdir(parents=True, exist_ok=True)
    shipped = []
    for repo in sorted(required | optional):
        database = source / f'{repo}.db'
        if not database.is_file():
            continue
        target = destination / database.name
        if target.is_symlink():
            raise RuntimeError(f'Symlink-backed destination database: {target}')
        # Pacman compares this mtime with the mirror on its next synchronization.
        shutil.copy2(database, target)
        shipped.append(repo)
    print(f'Shipping package indexes in the image: {" ".join(shipped)}')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('Usage: ship-sync-databases.py <image-root> <build-sync-dir>')
    try:
        ship(Path(sys.argv[1]), Path(sys.argv[2]))
    except (OSError, RuntimeError) as error:
        sys.exit(f'ERROR: {error}')
