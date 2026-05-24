#!/bin/bash
# Set GCS_WLAN_CONNECTION in /etc/default/gcs-ap-streaming (run as root).

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo $0 [ProfileName]"
    exit 1
fi

CONF="/etc/default/gcs-ap-streaming"
TEMPLATE="$(dirname "$0")/../config/gcs-ap-streaming.conf"

if [[ ! -f "$CONF" ]]; then
    install -m 644 "$TEMPLATE" "$CONF"
fi

if [[ $# -ge 1 ]]; then
    PROFILE="$1"
else
    echo "Wi‑Fi profiles (802-11-wireless):"
    nmcli -t -f NAME,TYPE connection show | awk -F: '$2=="802-11-wireless"{print "  "$1}'
    echo ""
    read -r -p "Profile name for wlan0 client: " PROFILE
fi

if ! nmcli -t -f NAME connection show | grep -Fxq "$PROFILE"; then
    echo "ERROR: unknown profile '$PROFILE'"
    exit 1
fi

if grep -q '^GCS_WLAN_CONNECTION=' "$CONF"; then
    sed -i "s/^GCS_WLAN_CONNECTION=.*/GCS_WLAN_CONNECTION=${PROFILE}/" "$CONF"
else
    echo "GCS_WLAN_CONNECTION=${PROFILE}" >>"$CONF"
fi

echo "Set GCS_WLAN_CONNECTION=${PROFILE} in $CONF"
echo "Reconnect: sudo /usr/local/bin/restore-wlan-client.sh"
echo "Or toggle AP off/on to apply on next AP start."
