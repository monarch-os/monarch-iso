# LUKS sector selection

New full-disk and protected free-space installations share `orchestrator/luks_calibration.py`, ported from Omarchy ISO `503aeb1`. Its executable Python AST matches upstream after branding; comments and docstrings are shortened to repository style. It requests 4096-byte encryption sectors when the target partition's byte size is divisible by 4096, otherwise leaves cryptsetup's defaults unchanged, including when the size probe fails. There is no retry of a failed format with different settings.

The policy is adapted from Omarchy ISO #336. Partition creation already uses an exclusive end converted to parted's inclusive `end - 1`. Logical partition sectors in the install JSON are separate from encryption sectors.

The free-space configurator invokes `monarch-luks-calibrate format` with its passphrase on stdin. Full-disk formatting uses upstream's per-encrypt wrapper through the archinstall adapter, restoring both the runner and original encrypt method on failure. Unlike upstream's broader `luks_tuning` module, the adapter does not change unlock flags, mapper lifetimes, chroot execution or locale generation.

The live-only `monarch-luks-calibrate.service` benchmarks Argon2id after mirror and root-image verification while the wizard is open. Both callers use upstream's 2000 ms / 512-bit-key policy. A completed root-owned boot-local cache replaces the search only with matching CPU count, full 1 GiB memory cost and sufficient memory headroom. Machines with less than 4 GiB usable RAM, reduced benchmark costs, missing or untrusted cache data and changed policies use ordinary cryptsetup calibration. Formatting cancels any pending benchmark first. The systemd sandbox denies disk access; no password or header is cached.

Existing volumes are not converted by upgrades, password changes or reconciliation. Changing their encryption sector size would require a separate supported reencryption procedure or reinstallation.

`test/unit/test_luks_format.py` covers selection, both entrypoints and real cryptsetup headers/password checks on disposable regular files. `test/unit/test_luks_calibration.py` covers cache integrity, policy and memory fallbacks, benchmark publication and service wiring. `bin/monarch-iso-test --encrypt` checks the root's LUKS sector size after first boot on new installs; use it both with and without `--free-space`. Reused base images retain their original format and are not subjected to the new-install assertion.
