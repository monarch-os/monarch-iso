import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/monarch-iso"))
sys.modules.setdefault("orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter"))
from orchestrator import phases_impl as phases


class EspMountTest(unittest.TestCase):
    def configurator_function(self, name):
        text = (ROOT / "configs/airootfs/root/configurator").read_text()
        return name + "() {" + text.split(name + "() {", 1)[1].split("\n}", 1)[0] + "\n}"

    def run_bash(self, script):
        # No external command can reach the host, even if the function changes.
        return subprocess.run(["/bin/bash", "--noprofile", "--norc", "-c", script],
                              env={"PATH": "/nonexistent"}, text=True, capture_output=True)

    def test_new_esp_clears_only_new_partition_signatures_and_mounts_typed(self):
        result = self.run_bash("""
set -eu
command_not_found_handle() { printf 'unexpected command: %s\n' "$*" >&2; exit 97; }
monarch-wait-mirror-verify() { :; }
step() { :; }
disk_abort_hook() { exit 98; }
disk_step() { shift; "$@"; }
create_partition() { if [[ $4 == fat32 ]]; then created_partition_number=2; else created_partition_number=3; fi; }
partition_path() { printf '%sp%s\n' "$1" "$2"; }
parted() { [[ $* == '--script /dev/mock set 2 esp on' ]]; }
partprobe() { :; }
sync() { :; }
sleep() { :; }
wait_for_device() { :; }
wipefs() {
  [[ $1 == -af ]]
  case $2 in
    /dev/mockp2) esp_signature=cleared ;;
    /dev/mockp3) root_signature=cleared ;;
    *) exit 96 ;;
  esac
  printf 'wipe %s\n' "$2"
}
mkfs.btrfs() { [[ $root_signature == cleared ]]; }
mkfs.fat() { [[ $esp_signature == cleared ]]; printf 'format %s\n' "${@: -1}"; }
mkdir() { :; }
rmdir() { :; }
umount() { :; }
btrfs() { :; }
mountpoint() { :; }
mount() {
  if [[ ${@: -2:1} == /dev/mockp2 ]]; then
    [[ $1 == -t && $2 == vfat ]] || return 32
    printf 'typed ESP %s\n' "${@: -1}"
  fi
}
write_protected_install_config() { :; }
disk=/dev/mock
esp_signature=old root_signature=old
needs_mklabel=false
encrypt_installation=false
EFI_START_B=1048576 EFI_END_B=210763776 ROOT_START_B=211812352 ROOT_END_B=1048576000
esp_mount_in_target=/efi
""" + self.configurator_function("run_partition_execute") + "\nrun_partition_execute\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["wipe /dev/mockp2", "wipe /dev/mockp3",
                                                     "format /dev/mockp2", "typed ESP /mnt/efi"])

    def test_windows_probe_is_typed_read_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "EFI/Microsoft").mkdir(parents=True)
            script = """
set -eu
blkid() { printf '/dev/mockp1\n'; }
mount() { [[ $1 == -t && $2 == vfat && $3 == -o && $4 == ro ]]; }
umount() { :; }
rmdir() { :; }
disk=/dev/mock
""" + f"mktemp() {{ printf '%s\\n' '{tmp}'; }}\n"
            result = self.run_bash(script + self.configurator_function("detect_windows_esp") + "\ndetect_windows_esp\n")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "/dev/mockp1")

    def test_protected_remount_names_vfat(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            for name in ("esp", "root"):
                (target / name).touch()
            ctx = types.SimpleNamespace(target=target, monarch_install={
                "boot": {"esp_mount": "/efi"},
                "storage": {"esp_device": str(target / "esp"), "root_device": str(target / "root")},
            })
            with mock.patch.object(phases, "_is_mountpoint", side_effect=[True, False]), \
                    mock.patch.object(phases.subprocess, "run") as run:
                phases.verify_protected_mounts(ctx)
            run.assert_called_once_with(["mount", "-t", "vfat", str(target / "esp"), str(target / "efi")], check=True)


if __name__ == "__main__":
    unittest.main()
