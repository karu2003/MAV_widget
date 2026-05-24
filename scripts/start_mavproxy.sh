#!/bin/bash
# Start MAVProxy for GCS (foreground — managed by systemd).

set -euo pipefail

CONF="${GCS_STREAMING_CONF:-/etc/default/gcs-ap-streaming}"
if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CONF"
fi

AP_IP="${AP_IP:-192.168.54.1}"
AP_BCAST="${AP_BCAST:-192.168.54.255}"
MAV_AP_BCAST_PORT="${MAV_AP_BCAST_PORT:-14550}"
MAV_AP_IN_PORT="${MAV_AP_IN_PORT:-14550}"

MAVPROXY="${HOME}/.local/bin/mavproxy.py"
if [[ ! -x "$MAVPROXY" ]]; then
    MAVPROXY="$(command -v mavproxy.py || true)"
fi
if [[ -z "$MAVPROXY" || ! -x "$MAVPROXY" ]]; then
    echo "[mavproxy] mavproxy.py not found" >&2
    exit 1
fi

if pgrep -f '[m]avproxy\.py' >/dev/null 2>&1; then
    echo "[mavproxy] Already running (pid $(pgrep -f '[m]avproxy\.py' | head -1))"
    exit 0
fi

if ! systemctl is-active --quiet hostapd 2>/dev/null; then
    echo "[mavproxy] hostapd not active (continuing — eth0 link may still work)" >&2
fi

sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.eth0.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.uap0.rp_filter=0 >/dev/null 2>&1 || true

MAV_OUTS=(
    --out=127.0.0.1:14551
    --out=127.0.0.1:14552
    --out="udpbcast:${AP_BCAST}:${MAV_AP_BCAST_PORT}"
)

# AP clients send mavlink to GCS on uap0 (skip bind if interface missing yet)
if ip link show uap0 &>/dev/null 2>&1; then
    MAV_OUTS+=(--out="udpin:${AP_IP}:${MAV_AP_IN_PORT}")
else
    echo "[mavproxy] uap0 down — AP uplink added when AP starts (restart mavproxy-gcs)" >&2
fi

echo "[mavproxy] Starting (foreground, force-connected, AP bcast ${AP_BCAST}:${MAV_AP_BCAST_PORT})..."
exec python3 "$MAVPROXY" \
    --master=udpin:192.168.53.1:14550 \
    "${MAV_OUTS[@]}" \
    --nowait \
    --force-connected \
    --non-interactive
