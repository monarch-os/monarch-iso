#!/bin/bash

set -euo pipefail

root=$(realpath "${BASH_SOURCE[0]%/*}/../..")
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/bin" "$fixture/source/default/sddm/monarch"
printf 'theme\n' >"$fixture/source/default/sddm/monarch/theme.conf"
git -C "$fixture/source" init -q
git -C "$fixture/source" add default
git -C "$fixture/source" -c user.name=Test -c user.email=test@example.com \
  -c commit.gpgsign=false commit -qm initial

cat >"$fixture/bin/pacman-key" <<'EOF'
#!/bin/bash
set -euo pipefail
git clone -q --no-local "$MONARCH_BUILD_TEST_SOURCE" "$MONARCH_BUILD_TEST_CHECKOUT"
exit 86
EOF
chmod 0755 "$fixture/bin/pacman-key"

export PATH="$fixture/bin:$PATH"
export MONARCH_BUILD_TEST_SOURCE="$fixture/source"
for mask in 0000 0077; do
  export MONARCH_BUILD_TEST_CHECKOUT="$fixture/checkout-$mask"
  set +e
  (umask "$mask"; bash "$root/builder/build-iso.sh")
  status=$?
  set -e
  ((status == 86)) || { echo "Builder did not stop at the test boundary" >&2; exit 1; }

  theme_dir="$MONARCH_BUILD_TEST_CHECKOUT/default/sddm/monarch"
  directory_mode=$(stat -c %a "$theme_dir")
  file_mode=$(stat -c %a "$theme_dir/theme.conf")
  if [[ $directory_mode != "755" || $file_mode != "644" ]]; then
    printf 'Inherited umask %s produced theme modes %s/%s, expected 755/644\n' \
      "$mask" "$directory_mode" "$file_mode" >&2
    exit 1
  fi
done

printf 'ok - ISO builder creates source files with stable permissions\n'
