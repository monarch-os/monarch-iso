#!/bin/bash

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

(
  export MONARCH_INTEGRATION_ISO="$tmp/candidate.iso"
  source "$root/test/integration.d/base-test.sh"
  trap - EXIT
  rmdir "$RUN_DIR" "$BASE_DIR/runs" "$BASE_DIR" 2>/dev/null || true
  BASE_DIR="$tmp/base"
  RUN_DIR="$tmp/run"
  mkdir -p "$BASE_DIR" "$RUN_DIR"
  SSH_KEY="$BASE_DIR/id_ed25519"
  CIDATA_IMG="$BASE_DIR/cidata.img"
  printf 'ssh-ed25519 test-key integration\n' >"$SSH_KEY.pub"

  qemu-system-x86_64() { printf '%s\n' "$@" >"$tmp/qemu-args"; }
  export MONARCH_INTEGRATION_OFFLINE=true
  ACCEL=tcg
  CPUS=2
  start_vm "$tmp/disk.qcow2" "$tmp/serial.log"
  grep -qxF 'q35,accel=tcg' "$tmp/qemu-args"
  grep -qxF max "$tmp/qemu-args"
  grep -qxF "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22,restrict=on" "$tmp/qemu-args"
  echo "ok - offline TCG boot retains only explicitly forwarded SSH"

  export MONARCH_INTEGRATION_OFFLINE=false
  ACCEL=kvm
  start_vm "$tmp/disk.qcow2" "$tmp/serial.log"
  grep -qxF 'q35,accel=kvm' "$tmp/qemu-args"
  grep -qxF host "$tmp/qemu-args"
  ! grep -q restrict=on "$tmp/qemu-args"
  echo "ok - normal integration runs retain KVM and network access"

  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/xorrisofs" <<'EOF'
#!/bin/bash
set -euo pipefail
for argument; do staging=$argument; done
cp "$staging/user_configuration.json" "$CIDATA_CAPTURE"
cp "$staging/authorized_keys" "$KEY_CAPTURE"
EOF
  chmod +x "$tmp/bin/xorrisofs"
  PATH="$tmp/bin:$PATH" CIDATA_CAPTURE="$tmp/config.json" KEY_CAPTURE="$tmp/key.pub" build_cidata
  jq -e '.hostname == "monarch-test" and .disk_config.device_modifications[0].device == "/dev/vda" and .monarch_install.mode == "full_disk"' "$tmp/config.json" >/dev/null
  cmp "$SSH_KEY.pub" "$tmp/key.pub"
  echo "ok - autoinstall uses the production configuration generator and the test SSH key"
)
