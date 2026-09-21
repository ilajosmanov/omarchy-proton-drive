#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fake=false
if [[ ${1:-} == --fake ]]; then fake=true; elif [[ ${1:-} != "" ]]; then printf 'Usage: %s [--fake]\n' "$0" >&2; exit 2; fi
if ! command -v omarchy >/dev/null; then printf 'This product installer requires Omarchy Quattro.\n' >&2; exit 1; fi
missing=()
for command in makepkg git bun; do command -v "$command" >/dev/null || missing+=("$command"); done
if ((${#missing[@]})); then printf 'Missing installer tools: %s\n' "${missing[*]}" >&2; exit 1; fi
printf 'Install Proton Drive for Omarchy?\n\n• background service\n• FUSE filesystem integration\n• Nautilus integration\n\n'
read -r -p 'Continue [y/N]? ' answer
[[ $answer == [yY] ]] || exit 0

install_stage=$(mktemp -d /tmp/omarchy-drive-install.XXXXXX)
trap 'rm -rf -- "$install_stage"' EXIT

# Build and verify the external authentication boundary before changing the
# installed package or user configuration. A failed upstream build therefore
# leaves the current integration untouched.
if ! $fake; then
  ./scripts/install-proton-cli.sh --output "$install_stage/proton-drive"
fi

(cd packaging/arch && makepkg -si --needed)
# The packaged extension in /usr/share/nautilus-python/extensions is the only
# registered copy. Stale user-dir copies (e.g. hand-copied dev versions) would
# double-register the Nautilus context menu.
stale_ext_dir="${XDG_DATA_HOME:-$HOME/.local/share}/nautilus-python/extensions"
rm -f -- "$stale_ext_dir/omarchy_drive.py" "$stale_ext_dir/drive_logic.py"
plugin_id="placq.proton-drive"
plugin_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$plugin_id"
mkdir -p "$plugin_dir"
cp -a manifest.json omarchy LICENSE README.md "$plugin_dir/"
mount_dir="${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-drive/mount"; mkdir -p "$mount_dir"
[[ $mount_dir != *$'\n'* ]] || { printf 'Mount path cannot contain a newline.\n' >&2; exit 1; }
mount_environment=${mount_dir//\\/\\\\}; mount_environment=${mount_environment//\"/\\\"}
bookmark_file="${XDG_CONFIG_HOME:-$HOME/.config}/gtk-3.0/bookmarks"; mkdir -p "$(dirname "$bookmark_file")"; touch "$bookmark_file"
bookmark_uri="file://${mount_dir// /%20} Proton Drive"
legacy_bookmark_uri="file://${HOME// /%20}/Proton%20Drive Proton Drive"
sed -i "\|^${legacy_bookmark_uri//|/\\|}$|d" "$bookmark_file"
grep -Fqx "$bookmark_uri" "$bookmark_file" || printf '%s\n' "$bookmark_uri" >> "$bookmark_file"
if $fake; then
  env_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-drive"; mkdir -p "$env_dir"; umask 077
  printf 'OMARCHY_DRIVE_PROVIDER=fake\nOMARCHY_DRIVE_MOUNT="%s"\n' "$mount_environment" > "$env_dir/environment"
  systemctl --user daemon-reload; systemctl --user reenable --now omarchy-drive.service omarchy-drive-dbus.service omarchy-drive-mount.service
else
  printf '\nThis is an unofficial third-party application not supported by Proton.\n'
  printf 'Authentication is handled by Proton Drive CLI in your browser; this project never receives your password.\n\n'
  cli_target="$HOME/.local/bin/proton-drive"
  mkdir -p "$(dirname "$cli_target")"
  cli_temporary="$cli_target.new.$$"
  install -m755 "$install_stage/proton-drive" "$cli_temporary"
  "$cli_temporary" version >/dev/null
  mv -f -- "$cli_temporary" "$cli_target"
  env_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-drive"; mkdir -p "$env_dir"; umask 077
  cli_environment=${cli_target//\\/\\\\}; cli_environment=${cli_environment//\"/\\\"}
  printf 'OMARCHY_DRIVE_PROVIDER=proton-cli\nOMARCHY_DRIVE_CLI="%s"\nOMARCHY_DRIVE_MOUNT="%s"\n' "$cli_environment" "$mount_environment" > "$env_dir/environment"
  systemctl --user daemon-reload; systemctl --user reenable --now omarchy-drive.service omarchy-drive-dbus.service omarchy-drive-mount.service
  printf 'Click the Proton icon in the Omarchy bar and choose Zaloguj się.\n'
fi
omarchy-shell shell rescanPlugins || true
omarchy plugin enable "$plugin_id" || true
omarchy bar move "$plugin_id" --after omarchy.agents || omarchy bar move "$plugin_id" --section right --index 1 || true
nautilus -q || true
printf 'Verifying installation…\n'
./scripts/doctor.sh
printf 'Installation step finished.\n'
