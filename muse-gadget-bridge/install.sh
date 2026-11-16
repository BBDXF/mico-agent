#!/usr/bin/env bash
set -euo pipefail

src_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
target_dir=/opt/mico-muse-bridge
env_file=/etc/mico-muse-bridge.env
unit_file=/etc/systemd/system/mico-muse-bridge.service

if ! id musegadget >/dev/null 2>&1; then
    echo "The Muse Gadget install must create the musegadget account first." >&2
    exit 1
fi

sudo install -d -o root -g root -m 0755 "$target_dir"
sudo install -o root -g root -m 0644 "$src_dir/bridge.py" "$target_dir/bridge.py"
sudo install -o root -g root -m 0644 "$src_dir/mico-muse-bridge.service" "$unit_file"

if ! sudo test -s "$env_file"; then
    token="$(openssl rand -hex 32)"
    tmp="$(mktemp)"
    printf 'MUSE_BRIDGE_TOKEN=%s\n' "$token" > "$tmp"
    sudo install -o root -g root -m 0600 "$tmp" "$env_file"
    rm -f "$tmp"
    unset token
fi

sudo systemctl daemon-reload
sudo systemctl enable --now mico-muse-bridge.service
printf 'Bridge installed. Its shared token is stored in %s (root-only); do not paste it into chat.\n' "$env_file"
printf 'When ready, copy it into mico-agent config as muse.bridge_token.\n'
