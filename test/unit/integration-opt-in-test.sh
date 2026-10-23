#!/bin/bash

set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/test/integration.d" "$tmp/bin"
cp "$root/test/integration" "$tmp/test/integration"
touch "$tmp/candidate.iso"
cat >"$tmp/test/integration.d/base-test.sh" <<'EOF'
BASE_DISK=fixture.qcow2
log() { :; }
base_image_ready() { return 0; }
EOF
cat >"$tmp/test/integration.d/normal-test.sh" <<'EOF'
echo normal >>"$SCENARIO_LOG"
EOF
cat >"$tmp/test/integration.d/extra-test.sh" <<'EOF'
# integration:opt-in
echo extra >>"$SCENARIO_LOG"
EOF
printf '#!/bin/bash\nexit 0\n' >"$tmp/bin/stub"
chmod +x "$tmp/bin/stub"
for tool in monarch-pkg-add qemu-system-x86_64 qemu-img socat magick tesseract xorrisofs ssh ssh-keygen jq openssl; do
  ln -s stub "$tmp/bin/$tool"
done
export SCENARIO_LOG="$tmp/scenarios" PATH="$tmp/bin:$PATH"
bash "$tmp/test/integration" "$tmp/candidate.iso" --reuse-base
[[ $(cat "$SCENARIO_LOG") == normal ]]
: >"$SCENARIO_LOG"
bash "$tmp/test/integration" "$tmp/candidate.iso" extra --reuse-base
[[ $(cat "$SCENARIO_LOG") == extra ]]
echo 'ok - opt-in scenarios are excluded by default and runnable explicitly'
