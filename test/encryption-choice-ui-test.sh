#!/bin/bash

set -e

root=$(realpath "${BASH_SOURCE[0]%/*}/..")
configurator="$root/configs/airootfs/root/configurator"

[[ $(grep -cF 'Disk encryption: ENABLED (LUKS)' "$configurator") -eq 2 ]]
[[ $(grep -cF 'Disk encryption: DISABLED' "$configurator") -eq 2 ]]
echo "ok - both disk flows display the current encryption state"

[[ $(grep -cF 'Press Ctrl+C to disable encryption before continuing.' "$configurator") -eq 2 ]]
[[ $(grep -cF 'Press Ctrl+C to enable encryption again.' "$configurator") -eq 2 ]]
echo "ok - both states explain the Ctrl+C toggle"

[[ $(grep -cF 'affirmative="Install with encryption"' "$configurator") -eq 2 ]]
[[ $(grep -cF 'affirmative="Install without encryption"' "$configurator") -eq 2 ]]
echo "ok - confirmation buttons name the selected encryption mode"
