# LUKS sector selection

New full-disk and protected free-space installations share `orchestrator/luks_format.py`. It requests 4096-byte LUKS2 encryption sectors when the target partition's byte size is divisible by 4096, otherwise explicitly requests 512. An unreadable, empty or non-512-aligned target stops before formatting. There is no retry of a failed format with different settings.

The policy is adapted from Omarchy ISO #336. Partition creation already uses an exclusive end converted to parted's inclusive `end - 1`. Logical partition sectors in the install JSON are separate from encryption sectors.

The free-space configurator invokes the helper with its passphrase on stdin. Full-disk formatting temporarily wraps the `run` function used by archinstall 4.5's `Luks2` during filesystem operations, restoring it even on failure. The wrapper only changes LUKS2 `luksFormat` commands without an explicit sector policy. Passwords, PBKDF settings and command results retain their existing transport and behavior.

Existing volumes are not converted by upgrades, password changes or reconciliation. Changing their encryption sector size would require a separate supported reencryption procedure or reinstallation.

`test/unit/test_luks_format.py` covers selection, failure propagation, both entrypoints and real cryptsetup headers/password checks on disposable regular files. `bin/monarch-iso-test --encrypt` checks the root's LUKS sector size after first boot on new installs; use it both with and without `--free-space`. Reused base images retain their original format and are not subjected to the new-install assertion.
