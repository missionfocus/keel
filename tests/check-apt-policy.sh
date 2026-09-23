#!/usr/bin/env bash
# Isolated APT parsing: no package changes, root privileges, or live services.
set -euo pipefail
root="$(dirname "$(dirname "$(realpath "$0")")")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/parts"
printf '%s\n' 'APT::Periodic::Enable "0";' > "$tmp/parts/docker-disable-periodic-update"
printf 'Dir::Etc::parts "%s";\nDir::Etc::main "/dev/null";\n' "$tmp/parts" > "$tmp/apt.conf"
query() {
    APT_CONFIG="$tmp/apt.conf" apt-config shell \
        periodic APT::Periodic::Enable \
        refresh APT::Periodic::Update-Package-Lists \
        upgrades APT::Periodic::Unattended-Upgrade \
        reboot Unattended-Upgrade::Automatic-Reboot
}
eval "$(query)"
[ "$periodic" = 0 ]
cp "$root/files/zz-keel-auto-upgrades" "$tmp/parts/"
eval "$(query)"
[ "$periodic/$refresh/$upgrades/$reboot" = '1/1/1/false' ]
echo 'ok: Keel policy overrides upstream disable; daily updates on, reboots off'
