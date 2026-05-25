#!/bin/bash
# Turn AP off from UI/CLI — set manual-off flag and tear down hostapd/uap0.

set -euo pipefail

# Acquire exclusive radio lock to prevent concurrent keepalive/restore races.
# FD 9 is inherited by child processes and automatically released on exit.
WLAN_LOCK="${WLAN_LOCK:-/run/gcs-wlan.lock}"
mkdir -p "$(dirname "$WLAN_LOCK")"
exec 9>"$WLAN_LOCK"
flock -w 30 9 || echo "[stop-ap-user] WARN: radio lock timeout — proceeding anyway"

/usr/local/bin/gcs-ap-manual-off.sh off
systemctl stop drone-hotspot.service 2>/dev/null || true
systemctl reset-failed drone-hotspot.service 2>/dev/null || true
/usr/local/bin/stop-drone-hotspot.sh --no-restore

wifi_state() {
    nmcli -t -f DEVICE,STATE device status 2>/dev/null \
        | awk -F: '$1=="wlan0" {print $2; exit}'
}

if command -v nmcli >/dev/null 2>&1 && ip link show wlan0 &>/dev/null; then
    nmcli device set wlan0 managed yes 2>/dev/null || true
    echo "[stop-ap-user] restoring wlan0 after AP off"
    timeout 120 /usr/local/bin/restore-wlan-client.sh --recover 2>/dev/null \
        || true

    state="$(wifi_state)"
    if [[ "$state" != "connected" ]]; then
        echo "[stop-ap-user] wlan0 state after restore: ${state:-unknown}"
    fi
fi
