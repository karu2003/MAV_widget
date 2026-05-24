#!/bin/bash
# Pin interface names (eth0=radio, eth1=USB) and restore static 192.168.53.1 on eth0.

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${PROJECT_DIR}/config"

log() { echo "[setup-network] $*"; }

log "Installing systemd .link rules (MAC -> eth0/eth1)..."
install -m 644 "${CONFIG}/10-gcs-builtin.link" /etc/systemd/network/10-gcs-builtin.link
install -m 644 "${CONFIG}/20-gcs-usb.link" /etc/systemd/network/20-gcs-usb.link
# udev NAME= rules conflict with systemd.link — remove if present.
rm -f /etc/udev/rules.d/70-gcs-net-names.rules
udevadm control --reload-rules 2>/dev/null || true

log "NetworkManager: no auto-default on eth0/eth1..."
install -m 644 "${CONFIG}/NetworkManager-gcs.conf" \
    /etc/NetworkManager/conf.d/gcs-no-auto-default.conf

log "Disabling cloud-init network overwrite..."
install -m 644 "${CONFIG}/99-disable-cloud-init-network.cfg" \
    /etc/cloud/cloud.cfg.d/99-disable-cloud-init-network.cfg

log "Installing NetworkManager profiles (match by MAC)..."
install -m 600 "${CONFIG}/gcs-eth0-radio.nmconnection" \
    /etc/NetworkManager/system-connections/GCS-Radio.nmconnection
install -m 600 "${CONFIG}/gcs-eth1-usb.nmconnection" \
    /etc/NetworkManager/system-connections/USB-Debug.nmconnection
chown root:root /etc/NetworkManager/system-connections/GCS-Radio.nmconnection \
    /etc/NetworkManager/system-connections/USB-Debug.nmconnection

install -m 755 "${PROJECT_DIR}/scripts/ensure_network.sh" /usr/local/bin/ensure-network.sh

sed "s|__PROJECT_DIR__|${PROJECT_DIR}|g" \
    "${PROJECT_DIR}/systemd/gcs-network.service" > /etc/systemd/system/gcs-network.service

while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    nmcli connection delete "$name" 2>/dev/null || true
    log "Removed profile: $name"
done < <(nmcli -t -f NAME connection show | grep -E '^Wired connection ' || true)

systemctl daemon-reload
systemctl enable gcs-network.service

log "Applying network now (swap names if needed)..."
/usr/local/bin/ensure-network.sh

log "Done. Reboot once so systemd .link rules apply at early boot."
"${PROJECT_DIR}/scripts/check-network.sh" || true
