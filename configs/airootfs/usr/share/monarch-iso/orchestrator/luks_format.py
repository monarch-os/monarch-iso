"""Sector policy shared by full-disk and protected free-space formatting."""

import os
import sys


def format_command(command: list[str]) -> list[str]:
    if (not command or command[0] != 'cryptsetup' or 'luksFormat' not in command
            or '--type' not in command
            or any(arg == '--sector-size' or arg.startswith('--sector-size=') for arg in command)):
        return command
    type_index = command.index('--type') + 1
    if command[type_index:type_index + 1] != ['luks2']:
        return command
    index = command.index('luksFormat') + 1
    if index >= len(command) or command[index].startswith('-'):
        raise ValueError('Expected the LUKS device immediately after luksFormat')
    device = command[index]
    fd = os.open(device, os.O_RDONLY | os.O_CLOEXEC)
    try:
        size = os.lseek(fd, 0, os.SEEK_END)
    finally:
        os.close(fd)
    if size <= 0 or size % 512:
        raise ValueError(f'Invalid LUKS device size: {size}')
    # cryptsetup rejects 4 KiB sectors on a partition with a partial final sector.
    sector = '4096' if size % 4096 == 0 else '512'
    return command[:index + 1] + ['--sector-size', sector] + command[index + 1:]


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit('usage: luks_format.py DEVICE')
    command = ['cryptsetup', 'luksFormat', sys.argv[1], '--type', 'luks2', '--batch-mode', '-']
    os.execvp('cryptsetup', format_command(command))


if __name__ == '__main__':
    main()
