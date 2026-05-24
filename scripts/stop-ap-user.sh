#!/bin/bash
# Turn AP off from UI/CLI — set manual-off flag and tear down hostapd/uap0.

set -euo pipefail

/usr/local/bin/gcs-ap-manual-off.sh off
/usr/local/bin/stop-drone-hotspot.sh
systemctl stop drone-hotspot.service 2>/dev/null || true
systemctl reset-failed drone-hotspot.service 2>/dev/null || true

# stop-drone-hotspot already runs restore --recover; retry once if still down
if command -v nmcli >/dev/null 2>&1 && ip link show wlan0 &>/dev/null; then
    state="$(nmcli -t -f STATE device show wlan0 2>/dev/null | head -1 || true)"
    if [[ "$state" != "connected" ]]; then
        echo "[stop-ap-user] wlan0 still down — retry restore"
        /usr/local/bin/restore-wlan-client.sh --recover 2>/dev/null \
            || true
    fi
fi
