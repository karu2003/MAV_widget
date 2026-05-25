#!/bin/bash
# Stop AP services and remove uap0 (video services stop separately — fast).

set -euo pipefail

AP="${AP:-uap0}"
GCS_AP_STATE="${GCS_AP_STATE:-/var/lib/gcs-ap}"
RESTORE_WLAN=true

case "${1:-}" in
    --no-restore)
        RESTORE_WLAN=false
        ;;
    "" )
        ;;
    *)
        echo "Usage: $0 [--no-restore]" >&2
        exit 2
        ;;
esac

echo "[drone-hotspot] Stopping dnsmasq and hostapd..."
systemctl disable --now gcs-wlan-keepalive.timer 2>/dev/null || true
rm -f "${GCS_AP_STATE}/ap-mode"
systemctl stop --no-block gcs-video-rtsp.service gcs-video-udp-relay.service 2>/dev/null || true
pkill -9 -f '[f]fmpeg.*rtsp.*8554' 2>/dev/null || true
pkill -9 -f '[m]ediamtx /run/mediamtx-gcs' 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
systemctl stop hostapd 2>/dev/null || true
# Force-kill only if systemctl stop left stray processes (e.g. started outside systemd).
pgrep -x hostapd &>/dev/null && pkill -9 hostapd 2>/dev/null || true
pgrep -x dnsmasq &>/dev/null && pkill -9 dnsmasq 2>/dev/null || true

for _ in 1 2 3 4 5; do
    ip link show "$AP" &>/dev/null || break
    echo "[drone-hotspot] Removing $AP"
    ip link set "$AP" down 2>/dev/null || true
    iw dev "$AP" del 2>/dev/null || true
    sleep 1
done

if [[ "$RESTORE_WLAN" == true ]] && command -v nmcli >/dev/null 2>&1 && ip link show wlan0 &>/dev/null; then
    nmcli device set wlan0 managed yes 2>/dev/null || true
    if [[ -x /usr/local/bin/restore-wlan-client.sh ]]; then
        echo "[drone-hotspot] Restoring wlan0 client (AP off)"
        timeout 120 /usr/local/bin/restore-wlan-client.sh --recover || true
    elif [[ -x "$(dirname "$0")/restore-wlan-client.sh" ]]; then
        timeout 120 "$(dirname "$0")/restore-wlan-client.sh" --recover || true
    fi
fi

echo "[drone-hotspot] Stopped"
