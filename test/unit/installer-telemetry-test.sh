#!/bin/bash

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
helper="$root/configs/airootfs/usr/local/bin/monarch-install-telemetry"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bash "$helper" --snapshot "$tmp/install.log" "$tmp/state.json" >"$tmp/output"
grep -q 'waiting for the orchestrator' "$tmp/output"
echo 'ok - early boot reports missing installer state explicitly'

cat >"$tmp/state.json" <<'EOF'
{"current_phase":"Installing CachyOS + Monarch","current_index":2,"total_phases":14,"phases":[]}
EOF
printf 'Installing base system\npacstrap progress\n' >"$tmp/install.log"
bash "$helper" --snapshot "$tmp/install.log" "$tmp/state.json" >"$tmp/output"
grep -qF 'phase: Installing CachyOS + Monarch (3/14)' "$tmp/output"
grep -qF 'Installing base system' "$tmp/output"
grep -qF 'pacstrap progress' "$tmp/output"
echo 'ok - actual phase and installer log are forwarded independently of dashboard tips'

jq '.phases = [{"status":"failed","name":"Installing CachyOS + Monarch","error":"sanity_check rejected offline"}]' "$tmp/state.json" >"$tmp/failed.json"
bash "$helper" --snapshot "$tmp/install.log" "$tmp/failed.json" >"$tmp/output"
grep -qF '[installer-state] failed: Installing CachyOS + Monarch: sanity_check rejected offline' "$tmp/output"
echo 'ok - failed phases preserve the installer error'

jq '.finished_at = 123' "$tmp/state.json" >"$tmp/finished.json"
bash "$helper" --snapshot "$tmp/install.log" "$tmp/finished.json" >"$tmp/output"
grep -qF '[installer-state] complete' "$tmp/output"
echo 'ok - installation completion is reported explicitly'
