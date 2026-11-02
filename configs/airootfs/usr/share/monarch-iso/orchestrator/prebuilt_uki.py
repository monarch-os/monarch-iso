"""Reuse a generic UKI only while its boot inputs still match the image."""

import hashlib
import json
import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path


def fingerprint(root: Path) -> str:
    digest = hashlib.sha256()
    paths = [root / 'etc/mkinitcpio.conf', root / 'usr/lib/monarch/snapshot-overlay',
             root / 'usr/lib/systemd/system/monarch-snapshot-overlay.service',
             root / 'usr/lib/monarch/boot/linuxx64.efi.stub']
    for directory in ('etc/mkinitcpio.conf.d', 'etc/modprobe.d', 'usr/lib/modprobe.d',
                      'usr/lib/initcpio/install', 'usr/lib/initcpio/hooks'):
        paths.extend(sorted((root / directory).glob('*')))
    for path in paths:
        if path.is_file():
            digest.update(str(path.relative_to(root)).encode() + b'\0' + path.read_bytes())
    vconsole = root / 'etc/vconsole.conf'
    text = vconsole.read_text() if vconsole.is_file() else ''
    settings = {}
    for line in text.splitlines():
        match = re.match(r'^\s*(KEYMAP|KEYMAP_TOGGLE|FONT|FONT_MAP|FONT_UNIMAP)=(.*?)\s*$', line)
        if match:
            settings[match[1]] = match[2].strip('"\'')
    settings.setdefault('KEYMAP', 'us')
    digest.update(json.dumps(settings, sort_keys=True).encode())
    for path in sorted((root / 'usr/lib/modules').glob('*/pkgbase')):
        digest.update(str(path.relative_to(root)).encode() + path.read_bytes())
    for directory in ('usr/lib/firmware/amd-ucode', 'usr/lib/firmware/intel-ucode'):
        for path in sorted((root / directory).rglob('*')):
            if path.is_file():
                digest.update(str(path.relative_to(root)).encode() + path.read_bytes())
    return digest.hexdigest()


def luks_uuid_of(spec: str) -> str:
    if spec.startswith('UUID='):
        return spec.removeprefix('UUID=')
    if spec.startswith('PARTUUID='):
        device = '/dev/disk/by-partuuid/' + spec.removeprefix('PARTUUID=')
    elif spec.startswith('/dev/'):
        device = spec
    else:
        raise RuntimeError(f'Unsupported cryptdevice source: {spec}')
    result = subprocess.run(['blkid', '-s', 'UUID', '-o', 'value', device],
                            check=True, capture_output=True, text=True, timeout=10)
    uuid = result.stdout.strip()
    if not uuid:
        raise RuntimeError(f'Cannot determine the LUKS UUID of {spec}')
    return uuid


def with_sd_encrypt(cmdline: str) -> str:
    """One command line for the prebuilt systemd UKI and later busybox rebuilds."""
    extra = []
    for param in cmdline.split():
        if not param.startswith('cryptdevice='):
            continue
        spec, separator, rest = param.removeprefix('cryptdevice=').partition(':')
        name, _, options = rest.partition(':')
        if not separator or not name:
            raise RuntimeError('Invalid cryptdevice mapping')
        uuid = luks_uuid_of(spec)
        if f'rd.luks.name={uuid}=' not in cmdline:
            extra.append(f'rd.luks.name={uuid}={name}')
        if options and f'rd.luks.options={uuid}=' not in cmdline:
            extra.append(f'rd.luks.options={uuid}={options.replace("allow-discards", "discard")}')
    return ' '.join(cmdline.split() + extra)


def embed_cmdline(path: Path, cmdline: str) -> bool:
    data = ' '.join(cmdline.split()).encode()
    with path.open('r+b') as image:
        header = image.read(4096)
        if len(header) < 64 or header[:2] != b'MZ':
            return False
        pe = struct.unpack_from('<I', header, 60)[0]
        if len(header) < pe + 24 or header[pe:pe + 4] != b'PE\0\0':
            return False
        count = struct.unpack_from('<H', header, pe + 6)[0]
        optional_size = struct.unpack_from('<H', header, pe + 20)[0]
        for index in range(count):
            entry = pe + 24 + optional_size + index * 40
            if len(header) < entry + 40:
                return False
            if header[entry:entry + 8].rstrip(b'\0') != b'.cmdline':
                continue
            virtual_size, _, raw_size, offset = struct.unpack_from('<IIII', header, entry + 8)
            room = min(virtual_size, raw_size)
            if room > 2048 or len(data) + 1 > room:
                return False
            image.seek(offset)
            old = image.read(room)
            if len(old) != room or b'monarch.cmdline_room=' not in old:
                return False
            image.seek(offset)
            image.write(data.ljust(room - 1, b' ') + b'\0')
            return True
    return False


def deploy(target: Path, esp: Path, prefix: str, cmdline: str) -> bool:
    cache = target / 'var/lib/monarch-iso'
    uki = cache / 'prebuilt-uki.efi'
    metadata = cache / 'prebuilt-uki.json'
    if not uki.is_file() or not metadata.is_file():
        print('Prebuilt UKI unavailable: image or metadata missing', flush=True)
        return False
    saved = json.loads(metadata.read_text())
    if saved['fingerprint'] != fingerprint(target):
        print('Prebuilt UKI unavailable: boot inputs changed', flush=True)
        return False
    if (target / 'etc/monarch/provisioning.key').exists():
        print('Prebuilt UKI unavailable: provisioning key requires embedding', flush=True)
        return False
    kernels = [p.read_text().strip() for p in (target / 'usr/lib/modules').glob('*/pkgbase')]
    if kernels != [saved['kernel']]:
        print('Prebuilt UKI unavailable: kernel selection changed', flush=True)
        return False
    if not re.fullmatch('[a-z0-9]+', prefix):
        prefix = (target / 'etc/machine-id').read_text().strip()
    if not re.fullmatch('[a-z0-9]+', prefix):
        raise RuntimeError('Cannot determine the UKI filename prefix')
    destination = esp / 'EFI/Linux' / f'{prefix}_{saved["kernel"]}.efi'
    destination.parent.mkdir(parents=True, exist_ok=True)
    staged = destination.with_suffix('.tmp')
    shutil.copy2(uki, staged)
    if not embed_cmdline(staged, cmdline):
        print('Prebuilt UKI unavailable: command line cannot be embedded', flush=True)
        staged.unlink()
        return False
    subprocess.run(['arch-chroot', str(target), 'limine-install', '--no-efi-register'], check=True)
    staged.replace(destination)
    subprocess.run(['arch-chroot', str(target), 'limine-entry-tool', '--add-uki', saved['kernel'],
                    '/' + str(destination.relative_to(target)), '--comment', 'Pre-built UKI',
                    '--no-mutex', '--no-hooks'], check=True)
    print('Prebuilt UKI reused', flush=True)
    return True


if __name__ == '__main__':
    root = Path(sys.argv[1])
    print(json.dumps({'fingerprint': fingerprint(root), 'kernel': sys.argv[2]}))
