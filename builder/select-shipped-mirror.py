#!/usr/bin/python3
"""Select target archives not already supplied, at the same version, by the image."""

import sys
import tarfile
from pathlib import Path


def select(mirror, image_index, reachable_index):
    image = {}
    for line in image_index.read_text().splitlines():
        name, version = line.split()
        if name in image:
            raise ValueError(f'Duplicate image package: {name}')
        image[name] = version
    if not image:
        raise ValueError('Empty root image package index')
    reachable = set(reachable_index.read_text().splitlines())
    if not reachable:
        raise ValueError('Empty installable package selection')
    records = {}
    with tarfile.open(mirror / 'offline.db.tar.gz') as database:
        for member in database:
            if not member.isfile() or not member.name.endswith('/desc'):
                continue
            fields = database.extractfile(member).read().decode().split('\n\n')
            fields = {lines[0]: lines[1:] for field in fields if (lines := field.splitlines())}
            name, version, filename = (fields[key][0] for key in ('%NAME%', '%VERSION%', '%FILENAME%'))
            if name in records or Path(filename).name != filename or '.pkg.tar.' not in filename:
                raise ValueError(f'Invalid mirror package: {name}')
            if not (mirror / filename).is_file():
                raise ValueError(f'Missing mirror package: {filename}')
            records[name] = (version, filename)
    if not reachable <= {filename for _, filename in records.values()}:
        raise ValueError('Installable selection references packages outside the mirror')
    if any(name not in records for name in image):
        raise ValueError('Image index references packages outside the mirror')
    shipped = sorted(filename for name, (version, filename) in records.items()
                     if filename in reachable and image.get(name) != version)
    if not shipped or len(shipped) >= len(records):
        raise ValueError('Shipped mirror selection is empty or removes no packages')
    return shipped


if __name__ == '__main__':
    print('\n'.join(select(*(Path(arg) for arg in sys.argv[1:]))))
