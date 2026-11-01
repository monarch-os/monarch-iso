"""Deploy the build-time Btrfs filesystem into an explicitly disposable root."""

from __future__ import annotations

import json
import os
import shutil
import shlex
import subprocess
import time
from pathlib import Path

IMAGE = Path('/var/cache/monarch/mirror/offline/monarch-root.img.zst')
STANDARD_SUBVOLUMES = {'@', '@home', '@log', '@pkg'}
FAT = {'vfat', 'msdos', 'fat', 'exfat'}


def image_size() -> int:
    if not IMAGE.is_file():
        raise RuntimeError(f'Root image missing: {IMAGE}')
    try:
        size = int(IMAGE.with_suffix(IMAGE.suffix + '.size').read_text().strip())
    except (OSError, ValueError) as exc:
        raise RuntimeError('Root image size metadata is missing or invalid') from exc
    if size <= 0 or size % 4096:
        raise RuntimeError('Root image size is not a positive multiple of 4096')
    return size


def validate_subvolumes(subvolumes: list[dict]) -> None:
    where = {}
    for subvolume in subvolumes:
        name = str(subvolume.get('name', '')).strip('/')
        mountpoint = Path(subvolume.get('mountpoint') or '')
        if not name or '..' in Path(name).parts or not mountpoint.is_absolute() or '..' in mountpoint.parts:
            raise RuntimeError('Invalid root image subvolume layout')
        if name in where or mountpoint in where.values():
            raise RuntimeError('Duplicate subvolume name or mountpoint')
        where[name] = mountpoint
    if where.get('@') != Path('/'):
        raise RuntimeError('Root image requires Btrfs subvolume @ mounted at /')
    for name, mountpoint in where.items():
        parents = [other for other in where if name.startswith(other + '/')]
        if not parents:
            continue
        parent = max(parents, key=len)
        if mountpoint != where[parent] / name[len(parent) + 1:]:
            raise RuntimeError(f'Nested subvolume {name} does not match its mountpoint')
        for other, other_mount in where.items():
            if other in (name, parent):
                continue
            if other_mount != where[parent] and other_mount != mountpoint \
                    and mountpoint.is_relative_to(other_mount) and other_mount.is_relative_to(where[parent]):
                raise RuntimeError(f'Subvolume {name} crosses the mount of {other}')


def validate_layout(ctx) -> None:
    image_size()
    disk = ctx.user_configuration.get('disk_config', {})
    if disk.get('lvm_config'):
        raise RuntimeError('Root images do not support LVM layouts')
    if ctx.is_protected:
        return
    for modification in disk.get('device_modifications') or []:
        for partition in modification.get('partitions') or []:
            subvolumes = partition.get('btrfs') or []
            if any(s.get('mountpoint') == '/' for s in subvolumes):
                if partition.get('fs_type') != 'btrfs' or not modification.get('wipe'):
                    raise RuntimeError('Root image requires an explicitly wiped Btrfs target')
                validate_subvolumes(subvolumes)
                return
    raise RuntimeError('Root image layout has no Btrfs root subvolume')


def mounts_under(target: Path) -> list[dict]:
    result = subprocess.run(['findmnt', '-R', '-J', '-o', 'TARGET,SOURCE,FSTYPE,OPTIONS', str(target)],
                            capture_output=True, text=True, check=True)
    mounts = []

    def walk(nodes):
        for node in nodes:
            mounts.append(node)
            walk(node.get('children') or [])

    walk(json.loads(result.stdout).get('filesystems') or [])
    return mounts


def subvolume_name(mount: dict) -> str:
    for option in (mount.get('options') or '').split(','):
        if option.startswith('subvol='):
            return option.split('=', 1)[1].strip('/')
    raise RuntimeError(f'Missing Btrfs subvolume name: {mount["target"]}')


def source_device(mount: dict) -> str:
    return (mount.get('source') or '').split('[')[0]


def target_layout(target: Path) -> tuple[list[dict], str, list[tuple[str, Path]]]:
    mounts = mounts_under(target)
    if not mounts or Path(mounts[0]['target']) != target or mounts[0]['fstype'] != 'btrfs':
        raise RuntimeError('Root image target is not a mounted Btrfs filesystem')
    device = source_device(mounts[0])
    if not device.startswith('/dev/'):
        raise RuntimeError('Root image target has no block device')
    layout = []
    for mount in mounts:
        path = Path(mount['target'])
        if not path.is_relative_to(target):
            raise RuntimeError('Mount lies outside the installation target')
        if source_device(mount) == device:
            if mount['fstype'] != 'btrfs':
                raise RuntimeError('Root device has a non-Btrfs mount')
            layout.append((subvolume_name(mount), path.relative_to(target)))
        elif mount['fstype'] not in FAT:
            raise RuntimeError('Root image supports only Btrfs subvolumes and FAT boot filesystems')
    validate_subvolumes([{'name': name, 'mountpoint': str(Path('/') / path)} for name, path in layout])
    return mounts, device, layout


def assert_empty(top: Path, allowed: set[str]) -> None:
    for entry in top.iterdir():
        if entry.name not in allowed or entry.is_symlink() or not entry.is_dir():
            raise RuntimeError(f'Root filesystem already contains {entry.name}; refusing image write')
    for directory, dirs, files in os.walk(top, followlinks=False):
        if files or any((Path(directory) / name).is_symlink() for name in dirs):
            raise RuntimeError('Root filesystem already contains files; refusing image write')


def unmount_tree(target: Path) -> None:
    for attempt in range(20):
        result = subprocess.run(['umount', '-R', str(target)], capture_output=True, text=True)
        if result.returncode == 0:
            return
        time.sleep(0.1)
    raise RuntimeError(f'Cannot unmount target: {result.stderr.strip()}')


def write_image(device: str) -> None:
    # Full blocks keep O_DIRECT effective; both processes must succeed.
    decoder = subprocess.Popen(['zstdcat', str(IMAGE)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        writer = subprocess.Popen(['dd', f'of={device}', 'bs=2M', 'iflag=fullblock',
                                   'oflag=direct', 'conv=fsync', 'status=none'],
                                  stdin=decoder.stdout, stderr=subprocess.PIPE)
    except BaseException:
        decoder.kill()
        decoder.communicate()
        raise
    decoder.stdout.close()
    try:
        _, writer_error = writer.communicate()
        _, decoder_error = decoder.communicate()
    except BaseException:
        writer.kill()
        decoder.kill()
        writer.wait()
        decoder.wait()
        raise
    if writer.returncode or decoder.returncode:
        raise RuntimeError(f'Root image write failed: {writer_error.decode(errors="replace")} '
                           f'{decoder_error.decode(errors="replace")}')


def refresh_uuid(device: str) -> None:
    subprocess.run(['btrfstune', '-f', '-m', device], check=True)
    result = subprocess.run(['btrfs', 'inspect-internal', 'dump-super', device],
                            capture_output=True, text=True, check=True)
    wanted = next((line.split()[-1] for line in result.stdout.splitlines() if line.startswith('fsid')), '')
    for attempt in range(50):
        subprocess.run(['udevadm', 'trigger', '--settle', '--action=change', device],
                       check=False, capture_output=True)
        values = [subprocess.run(['blkid', *flags, '-s', 'UUID', '-o', 'value', device],
                                 capture_output=True, text=True, check=True).stdout.strip()
                  for flags in (['-p'], [])]
        if wanted and values == [wanted, wanted]:
            return
        time.sleep(0.1)
    raise RuntimeError('The new Btrfs UUID is not visible to blkid')


def image_directory(top: Path, placed: list[tuple[str, Path]], path: Path) -> Path:
    candidates = [(name, mount) for name, mount in placed if path.is_relative_to(mount)]
    name, mount = max(candidates, key=lambda item: len(item[1].parts))
    return top / name / path.relative_to(mount)


def create_subvolume(top: Path, name: str, content: Path) -> None:
    destination = top / name
    staged = None
    if destination.exists():
        staged = destination.with_name(destination.name + '.monarch-image')
        destination.rename(staged)
        if content == destination:
            content = staged
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['btrfs', 'subvolume', 'create', str(destination)], check=True)
    if content.is_dir():
        subprocess.run(['cp', '-a', '--reflink=always', f'{content}/.', str(destination)], check=True)
        for entry in list(content.iterdir()):
            if entry.is_dir() and not entry.is_symlink():
                shutil.rmtree(entry)
            else:
                entry.unlink()
    if staged:
        shutil.rmtree(staged)


def copy_fat_tree(content: Path, destination: Path, keep: set[Path], seen=frozenset()) -> None:
    real = content.resolve()
    if real in seen:
        return
    destination.mkdir(parents=True, exist_ok=True)
    for entry in content.iterdir():
        name = Path(entry.name)
        if name in keep:
            continue
        if entry.is_dir():
            copy_fat_tree(entry, destination / name,
                          {p.relative_to(name) for p in keep if p.is_relative_to(name)}, seen | {real})
        elif entry.is_file():
            shutil.copy2(entry, destination / name)


def remove_fat_tree(content: Path, keep: set[Path]) -> None:
    for entry in list(content.iterdir()):
        name = Path(entry.name)
        if name in keep:
            continue
        inner = {p.relative_to(name) for p in keep if p.is_relative_to(name)}
        if entry.is_dir() and not entry.is_symlink():
            if inner:
                remove_fat_tree(entry, inner)
            else:
                shutil.rmtree(entry)
        else:
            entry.unlink()


def install(ctx) -> None:
    mounts, device, layout = target_layout(ctx.target)
    filesystem = subprocess.run(['btrfs', 'filesystem', 'show', '--raw', device],
                                capture_output=True, text=True, check=True).stdout
    if not any(line.strip().startswith('Total devices 1 ') for line in filesystem.splitlines()):
        raise RuntimeError('Root image requires a single-device Btrfs filesystem')
    size = image_size()
    capacity = int(subprocess.run(['blockdev', '--getsize64', device], capture_output=True,
                                  text=True, check=True).stdout)
    if capacity < size:
        raise RuntimeError(f'Root partition is too small for the image ({size} bytes required)')
    top = ctx.state_dir / 'image-top'
    top.mkdir(parents=True, exist_ok=True)
    subprocess.run(['mount', '-o', 'ro,subvolid=5', device, str(top)], check=True)
    try:
        allowed = STANDARD_SUBVOLUMES if ctx.is_protected else {Path(name).parts[0] for name, _ in layout}
        assert_empty(top, allowed)
    finally:
        subprocess.run(['umount', str(top)], check=True)

    unmount_tree(ctx.target)
    remaining = subprocess.run(['findmnt', '-rn', '-S', device], capture_output=True, text=True)
    if remaining.returncode != 1:
        raise RuntimeError('Cannot confirm the root device is unmounted; refusing image write')
    write_image(device)
    refresh_uuid(device)
    fat_paths = [Path(m['target']).relative_to(ctx.target) for m in mounts if m['fstype'] in FAT]
    stage = ctx.state_dir / 'image-esp'
    shutil.rmtree(stage, ignore_errors=True)
    subprocess.run(['mount', '-o', 'subvolid=5', device, str(top)], check=True)
    try:
        subprocess.run(['btrfs', 'filesystem', 'resize', 'max', str(top)], check=True)
        (top / 'monarch-root').rename(top / '@')
        placed = [('@', Path('.'))]
        for name, mountpoint in sorted(layout, key=lambda item: (len(item[1].parts), item[0].count('/'))):
            if name == '@':
                continue
            create_subvolume(top, name, image_directory(top, placed, mountpoint))
            placed.append((name, mountpoint))
        trees = []
        for path in fat_paths:
            content = image_directory(top, placed, path)
            if not content.is_dir() or content.is_symlink():
                continue
            keep = {other.relative_to(path) for other in fat_paths + [p for _, p in placed]
                    if other != path and other.is_relative_to(path)}
            trees.append((path, content, keep))
        for path, content, keep in trees:
            copy_fat_tree(content, stage / path, keep)
        for path, content, keep in trees:
            remove_fat_tree(content, keep)
    finally:
        subprocess.run(['umount', str(top)], check=True)
    for mount in mounts:
        path = Path(mount['target'])
        path.mkdir(parents=True, exist_ok=True)
        options = ','.join(opt for opt in mount['options'].split(',') if not opt.startswith('subvolid='))
        subprocess.run(['mount', '-o', options, source_device(mount), str(path)], check=True)
    for path in fat_paths:
        if (stage / path).is_dir():
            subprocess.run(['cp', '-r', f'{stage / path}/.', str(ctx.target / path)], check=True)
    shutil.rmtree(stage, ignore_errors=True)
    local_db = ctx.target / 'var/lib/pacman/local'
    installed = {p.name.rsplit('-', 2)[0] for p in local_db.iterdir() if (p / 'desc').is_file()}
    missing = {'monarch', 'limine', 'archlinux-keyring', 'cachyos-keyring', 'monarch-keyring'} - installed
    if missing:
        raise RuntimeError(f'Root image lacks required packages: {", ".join(sorted(missing))}')
    subprocess.run(['systemd-machine-id-setup', f'--root={ctx.target}'], check=True)


def initialize_keyring(target: Path) -> None:
    gpgdir = shlex.quote(str(target / 'etc/pacman.d/gnupg'))
    keyrings = shlex.quote(str(target / 'usr/share/pacman/keyrings'))
    # systemd owns the agents' cgroup so they cannot retain the target mount.
    script = (f'pacman-key --gpgdir {gpgdir} --init && '
              f'pacman-key --gpgdir {gpgdir} --populate-from {keyrings} --populate archlinux cachyos monarch')
    subprocess.run(['systemd-run', '--wait', '--pipe', '--collect', '--quiet',
                    'sh', '-c', script], check=True)
