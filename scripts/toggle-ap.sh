#!/bin/bash
# Toggle drone AP (drone-hotspot.service: uap0 + hostapd + dnsmasq).

set -euo pipefail

SSID="$(grep -E '^ssid=' /etc/hostapd/drone-hotspot.conf 2>/dev/null | cut -d= -f2- || echo 'AP')"
AP_IP="192.168.54.1"

notify() {
    if command -v notify-send >/dev/null; then
        notify-send -i "${2:-network-wireless}" "GCS Wi-Fi AP" "$1"
    fi
    echo "[toggle-ap] $1"
}

ap_running() {
    systemctl is-active --quiet hostapd 2>/dev/null && ip link show uap0 &>/dev/null
}

if ap_running; then
    sudo systemctl stop drone-hotspot.service
    notify "AP off (${SSID})" "network-wireless-disconnected"
else
    sudo systemctl start drone-hotspot.service
    sleep 1
    if ap_running; then
        notify "AP on: ${SSID}  ${AP_IP}" "network-wireless"
    else
        notify "Failed to start AP — see: journalctl -u drone-hotspot -b" "dialog-warning"
        exit 1
    fi
fi
