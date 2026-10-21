#!/usr/bin/env python3
"""Fail-closed boot-menu checks for the initramfs rebuild integration test."""

import hashlib
import json
import re
import sys
from pathlib import Path


def snapshot(config, esp):
    text = Path(config).read_text()
    entries = []
    stack = []
    visible = []
    default = "1"
    for line in text.splitlines():
        header = re.fullmatch(r"\s*(/+)(\+?)([^/].*)", line)
        if header:
            depth = len(header[1])
            if depth > len(stack) + 1:
                raise ValueError("invalid menu nesting")
            stack = stack[:depth - 1]
            entry = {
                "title": header[3].strip(), "open": bool(header[2]),
                "ancestors": list(stack), "lines": [],
            }
            entries.append(entry)
            index = len(entries) - 1
            if all(entries[parent]["open"] for parent in stack):
                visible.append(index)
            stack.append(index)
        elif entries:
            entries[-1]["lines"].append(line)
        elif match := re.fullmatch(r"\s*default_entry:\s*(\S+)\s*", line):
            default = match[1]

    if not entries:
        raise ValueError("empty boot menu")
    if default.isdecimal():
        position = max(int(default), 1) - 1
        if position >= len(visible):
            raise ValueError("default_entry is outside the visible menu")
        selected = visible[position]
    else:
        raise ValueError("unsupported default_entry (expected a numeric index)")

    entry = entries[selected]
    fields = []
    for line in entry["lines"]:
        if match := re.fullmatch(r"\s*([a-z_]+):\s*(.*?)\s*", line):
            fields.append((match[1], match[2]))
    if ("protocol", "efi") not in fields:
        raise ValueError("default entry is not an EFI/UKI entry")
    paths = [value for key, value in fields if key == "path" or key.endswith("_path")]
    if not paths:
        raise ValueError("default entry loads no files")
    files = {}
    esp = Path(esp).resolve()
    for value in paths:
        match = re.fullmatch(r"boot\(\):(/[^#]+)#([0-9a-fA-F]{128})", value)
        if not match:
            raise ValueError(f"unsupported or unhashed boot path: {value}")
        path, expected = match.groups()
        target = (esp / path.lstrip("/")).resolve()
        if not target.is_relative_to(esp):
            raise ValueError(f"boot path escapes ESP: {path}")
        digest = hashlib.blake2b()
        with target.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != expected.lower():
            raise ValueError(f"BLAKE2b mismatch: {path}")
        files[path] = expected.lower()
    if not any(re.fullmatch(r"/EFI/Linux/monarch_[^/]+\.efi", path) for path in files):
        raise ValueError("default entry does not load a Monarch UKI")

    # Only the selected OS group may be rewritten. Keep the other groups byte
    # for byte, rather than removing their machine IDs to imitate vm-seal.
    own_group = entry["ancestors"][0] if entry["ancestors"] else selected
    foreign = [
        {"title": item["title"], "lines": item["lines"]}
        for index, item in enumerate(entries)
        if index != own_group and own_group not in item["ancestors"]
    ]
    return {
        "entries": [[item["title"], item["open"], item["ancestors"]] for item in entries],
        "selected": selected, "files": files, "foreign": foreign,
    }


def compare(before, after):
    for key in ("entries", "selected", "foreign"):
        if before[key] != after[key]:
            raise ValueError(f"boot menu changed unexpectedly: {key}")
    # Identical rebuilt UKIs are valid: reproducible builds need not change a
    # digest. snapshot has already checked every referenced file against disk.
    if before["files"].keys() != after["files"].keys():
        raise ValueError("default entry changed its boot file paths")


def main():
    if sys.argv[1] == "snapshot":
        print(json.dumps(snapshot(sys.argv[2], sys.argv[3]), indent=2))
    elif sys.argv[1] == "compare":
        compare(*(json.loads(Path(path).read_text()) for path in sys.argv[2:4]))
    else:
        raise ValueError("expected snapshot or compare")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        sys.exit(str(error))
