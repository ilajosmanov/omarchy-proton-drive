#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

test_root=$(mktemp -d /tmp/omarchy-drive-package-layout.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT
(
  startdir="$PWD/packaging/arch"
  pkgdir="$test_root/root"
  source packaging/arch/PKGBUILD
  package
)

package_root="$test_root/root"
for path in \
  usr/bin/omarchy-drive-control \
  usr/lib/omarchy-drive/daemon/src/main.ts \
  usr/lib/omarchy-drive/daemon/src/official-cli-provider.ts \
  usr/lib/omarchy-drive/daemon/src/settings.ts \
  usr/lib/omarchy-drive/filesystem/fuse/omarchy-drive-fuse.py \
  usr/lib/omarchy-drive/ipc/rpc_client.py \
  usr/lib/omarchy-drive/ipc/wait_secret_service.py \
  usr/lib/omarchy-drive/ipc/dbus/omarchy_drive_dbus.py; do
  [[ -f $package_root/$path ]] || { printf 'Packaged file missing: %s\n' "$path" >&2; exit 1; }
done
if find "$package_root/usr/lib/omarchy-drive" -type f \( -path '*/daemon/tests/*' -o -name 'test_*.py' -o -name '*.pyc' \) -print -quit | grep -q .; then
  printf 'Package unexpectedly contains tests or bytecode.\n' >&2
  exit 1
fi
PYTHONPYCACHEPREFIX="$test_root/pycache" "$package_root/usr/bin/omarchy-drive-control" --help >/dev/null
PYTHONPYCACHEPREFIX="$test_root/pycache" python3 -m py_compile \
  "$package_root/usr/lib/omarchy-drive/ipc/rpc_client.py" \
  "$package_root/usr/lib/omarchy-drive/ipc/dbus/omarchy_drive_dbus.py" \
  "$package_root/usr/lib/omarchy-drive/filesystem/fuse/omarchy-drive-fuse.py"
printf 'Package layout and Python entry points passed.\n'
