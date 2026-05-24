#!/bin/bash
# Optional: prefer one NetworkManager profile for wlan0 (any profile works if unset).

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
    echo "Wi‑Fi profiles (optional preference — AP works with any profile):"
    nmcli -t -f NAME,TYPE connection show | awk -F: '$2=="802-11-wireless"{print "  "$1}'
    echo ""
    read -r -p "Preferred profile (empty = auto / any): " PROFILE
fi

if [[ -z "${PROFILE:-}" ]]; then
    if grep -q '^GCS_WLAN_CONNECTION=' "$CONF"; then
        sed -i 's/^GCS_WLAN_CONNECTION=.*/GCS_WLAN_CONNECTION=/' "$CONF"
    fi
    echo "Cleared GCS_WLAN_CONNECTION — wlan0 will use any saved profile (autoconnect first)"
    exit 0
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

echo "Preferred profile: ${PROFILE} (others still tried if this fails)"
echo "Apply: sudo systemctl restart drone-hotspot  # or toggle AP"
