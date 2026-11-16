"""Read-only acceptance checks on a newly installed encrypted test guest."""
import json
from pathlib import Path
import subprocess


def output(*command):
    return subprocess.check_output(command, text=True).strip()


source = output('findmnt', '-nro', 'SOURCE', '/').split('[', 1)[0]
status = output('cryptsetup', 'status', source)
device = next(line.split(':', 1)[1].strip() for line in status.splitlines() if line.strip().startswith('device:'))
metadata = json.loads(output('cryptsetup', 'luksDump', '--dump-json-metadata', device))
assert metadata['segments']['0']['sector_size'] == 4096, metadata['segments']
flags = metadata['config'].get('flags', [])
assert {'allow-discards', 'no-read-workqueue'} <= set(flags), flags
cmdline = Path('/proc/cmdline').read_text()
assert 'allow-discards,no-read-workqueue' in cmdline, cmdline
assert 'discard,no-read-workqueue' in cmdline, cmdline
have = {locale.replace('-', '').lower() for locale in output('localedef', '--list-archive').split()}
wanted = [line.split()[0] for line in Path('/etc/locale.gen').read_text().splitlines()
          if line.strip() and not line.lstrip().startswith('#')]
assert wanted and all(locale.replace('-', '').lower() in have for locale in wanted), (wanted, have)
print(json.dumps({'sector_size': 4096, 'persistent_flags': flags, 'locales': wanted,
                  'cmdline': cmdline.strip()}, indent=2))
