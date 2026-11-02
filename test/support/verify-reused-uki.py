"""Verify the installed UKI is the prebuilt image with only its command line changed."""

import hashlib
import json
import struct
from pathlib import Path

cache = Path('/var/lib/monarch-iso')
metadata = json.loads((cache / 'prebuilt-uki.json').read_text())
original = (cache / 'prebuilt-uki.efi').read_bytes()
candidates = list(Path('/boot/EFI/Linux').glob(f'*_{metadata["kernel"]}.efi'))
assert len(candidates) == 1, candidates
installed = candidates[0].read_bytes()
pe = struct.unpack_from('<I', original, 60)[0]
count = struct.unpack_from('<H', original, pe + 6)[0]
optional_size = struct.unpack_from('<H', original, pe + 20)[0]
for index in range(count):
    entry = pe + 24 + optional_size + index * 40
    if original[entry:entry + 8].rstrip(b'\0') == b'.cmdline':
        virtual_size, _, raw_size, offset = struct.unpack_from('<IIII', original, entry + 8)
        end = offset + min(virtual_size, raw_size)
        assert b'root=' in installed[offset:end]
        assert original[:offset] == installed[:offset]
        assert original[end:] == installed[end:]
        print('Reused image SHA256:', hashlib.sha256(installed).hexdigest())
        break
else:
    raise AssertionError('Missing .cmdline section')
