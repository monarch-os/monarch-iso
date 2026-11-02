#!/usr/bin/env python3
"""Exercise an EFI stub before Linux; run under a host memory-limited scope."""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True, stdout=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stub', type=Path)
    parser.add_argument('output', type=Path, help='new directory for disposable images')
    parser.add_argument('--layout', choices=('two-esp', 'single', 'xbootldr'), default='two-esp')
    parser.add_argument('--stock', action='store_true', help='expect the original wrong-ESP write')
    args = parser.parse_args()
    stub = args.stub.resolve()
    work = args.output.resolve()
    header = stub.read_bytes()
    work.mkdir(exist_ok=False)
    disk = work / 'disk.raw'
    size = 64 * 1024 * 1024
    starts = (2048, 133120)
    with disk.open('wb') as image:
        image.truncate(140 * 1024 * 1024)
    run('sgdisk', '-og', '-n', '1:2048:+64M', '-t',
        '1:0700' if args.layout == 'single' else '1:ef00',
        '-n', '2:133120:+64M', '-t',
        '2:ea00' if args.layout == 'xbootldr' else '2:ef00', disk)

    # Stop after random-seed processing: an invalid kernel prevents Linux writes.
    (work / 'payload').write_bytes(b'pre-kernel random seed probe\0')
    pe = struct.unpack_from('<I', header, 60)[0]
    base = struct.unpack_from('<Q', header, pe + 48)[0]
    image_size = struct.unpack_from('<I', header, pe + 80)[0]
    run('objcopy', '--add-section', f'.linux={work / "payload"}',
        '--change-section-vma', f'.linux={base + image_size:#x}', stub, work / 'probe.efi')
    before, seeds = [], []
    for index, start in enumerate(starts):
        fat = work / f'partition-{index + 1}.fat'
        with fat.open('wb') as image:
            image.truncate(size)
        run('mformat', '-i', fat, '-F', '::')
        run('mmd', '-i', fat, '::/loader')
        seeds.append(os.urandom(32))
        (work / 'seed').write_bytes(seeds[-1])
        run('mcopy', '-i', fat, work / 'seed', '::/loader/random-seed')
        if index == 1:
            run('mmd', '-i', fat, '::/EFI', '::/EFI/BOOT')
            run('mcopy', '-i', fat, work / 'probe.efi', '::/EFI/BOOT/BOOTX64.EFI')
        data = fat.read_bytes()
        before.append(hashlib.sha256(data).hexdigest())
        with disk.open('r+b') as image:
            image.seek(start * 512)
            image.write(data)
    with disk.open('rb') as image:
        gpt_before = image.read(2048 * 512)
        image.seek(-33 * 512, os.SEEK_END)
        backup_gpt_before = image.read()
    shutil.copyfile('/usr/share/edk2/x64/OVMF_VARS.4m.fd', work / 'vars.fd')
    with (work / 'console.log').open('wb') as log:
        proc = subprocess.Popen([
            'qemu-system-x86_64', '-enable-kvm', '-machine', 'q35', '-cpu', 'host',
            '-smp', '2', '-m', '4096', '-display', 'none', '-monitor', 'none',
            '-serial', 'stdio', '-nic', 'none', '-no-reboot',
            '-drive', 'if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd',
            '-drive', f'if=pflash,format=raw,file={work / "vars.fd"}',
            '-drive', f'format=raw,file={disk}', '-device', 'virtio-rng-pci',
        ], stdout=log, stderr=subprocess.STDOUT)
        try:
            proc.wait(timeout=90)
        except subprocess.TimeoutExpired:
            pass
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()

    after, seed_changed = [], []
    with disk.open('rb') as image:
        assert image.read(2048 * 512) == gpt_before, 'GPT changed'
        image.seek(-33 * 512, os.SEEK_END)
        assert image.read() == backup_gpt_before, 'Backup GPT changed'
        for start, seed in zip(starts, seeds):
            image.seek(start * 512)
            after.append(hashlib.sha256(image.read(size)).hexdigest())
            current = subprocess.check_output(['mtype', '-i', f'{disk}@@{start * 512}',
                                               '::/loader/random-seed'])
            assert len(current) == 32, 'Unexpected random-seed size'
            seed_changed.append(current != seed)
    foreign_selected = args.layout == 'xbootldr' or (args.stock and args.layout == 'two-esp')
    assert seed_changed == [foreign_selected, not foreign_selected], seed_changed
    if not foreign_selected:
        assert before[0] == after[0], 'Foreign partition changed'
    print(f'PASS {args.layout}: seed changes={seed_changed}; '
          f'foreign partition unchanged={before[0] == after[0]}')


if __name__ == '__main__':
    main()
