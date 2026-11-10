#!/bin/bash
set -euo pipefail

# Pin trust before downloading the keyring package from the repository it protects.
fingerprint=519BC3D5AEA652C94F89F0AAC13B3766D969CE82
timeout --kill-after=5s 120s pacman-key --keyserver hkps://keys.openpgp.org --recv-keys "$fingerprint"
actual=$(gpg --batch --homedir /etc/pacman.d/gnupg --with-colons --fingerprint "$fingerprint" |
  awk -F: '$1 == "pub" { primary = 1; next } primary && $1 == "fpr" { print $10; primary = 0 }')
if [[ $actual != "$fingerprint" ]]; then
  echo "Monarch signing key fingerprint mismatch; refusing package downloads" >&2
  exit 1
fi
pacman-key --lsign-key "$fingerprint"
