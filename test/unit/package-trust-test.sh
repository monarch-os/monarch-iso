#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "${BASH_SOURCE[0]%/*}/../.." && pwd)
test_tmp=$(mktemp -d)
trap 'rm -rf -- "$test_tmp"' EXIT

policy=$(pacman-conf --config "$ROOT/configs/pacman-online.conf" --repo monarch SigLevel)
grep -qx PackageRequired <<<"$policy"
grep -qx PackageTrustedOnly <<<"$policy"
! grep -qE 'Package(Optional|TrustAll)' <<<"$policy"

mkdir "$test_tmp/bin"
export TRUST_CALLS="$test_tmp/calls"
cat >"$test_tmp/bin/pacman-key" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$TRUST_CALLS"
[[ ${TRUST_RECV_FAIL:-0} == 0 || $* != *--recv-keys* ]]
EOF
cat >"$test_tmp/bin/gpg" <<'EOF'
#!/bin/bash
printf 'pub:-:4096:1:fixture:0:0:::::scSC:\nfpr:::::::::%s:\n' "${TRUST_FINGERPRINT:-519BC3D5AEA652C94F89F0AAC13B3766D969CE82}"
EOF
chmod +x "$test_tmp/bin/"*
PATH="$test_tmp/bin:$PATH" bash "$ROOT/builder/bootstrap-monarch-keyring.sh"
grep -qx -- '--lsign-key 519BC3D5AEA652C94F89F0AAC13B3766D969CE82' "$TRUST_CALLS"
for failure in fingerprint receive; do
  : >"$TRUST_CALLS"
  if [[ $failure == fingerprint ]]; then
    export TRUST_FINGERPRINT=0000000000000000000000000000000000000000 TRUST_RECV_FAIL=0
  else
    export TRUST_FINGERPRINT=519BC3D5AEA652C94F89F0AAC13B3766D969CE82 TRUST_RECV_FAIL=1
  fi
  if PATH="$test_tmp/bin:$PATH" bash "$ROOT/builder/bootstrap-monarch-keyring.sh"; then
    echo "FAIL: trusted failed bootstrap: $failure" >&2
    exit 1
  fi
  ! grep -q -- --lsign-key "$TRUST_CALLS"
done
echo 'PASS: package signatures required; pinned bootstrap rejects foreign keys and retrieval failures'
