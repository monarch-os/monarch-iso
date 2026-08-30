#!/bin/bash

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
monarch_root=${MONARCH_PATH:-$root/../monarch}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat >"$tmp/bin/noctalia" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$NOCTALIA_CALLS"
EOF
chmod +x "$tmp/bin/noctalia"

NOCTALIA_CALLS="$tmp/calls" PATH="$tmp/bin:/usr/bin" \
  bash "$monarch_root/install/user/first-run/enable-noctalia-plugins.sh"

for plugin_id in monarch/indicators monarch/agents monarch/menu monarch/wifi-qr monarch/network monarch/display; do
  grep -qxF "msg plugins enable $plugin_id" "$tmp/calls"
done
grep -qxF 'msg shell config-reload' "$tmp/calls"

echo "ok - first run enables every packaged Noctalia plugin"
