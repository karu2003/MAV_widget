#!/bin/bash
# Start MAVProxy for GCS (foreground — managed by systemd).

set -euo pipefail

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

echo "[mavproxy] Starting (foreground, force-connected)..."
exec python3 "$MAVPROXY" \
    --master=udpin:192.168.53.1:14550 \
    --out=127.0.0.1:14551 \
    --out=127.0.0.1:14552 \
    --out=udpbcast:192.168.54.255:14550 \
    --nowait \
    --force-connected \
    --non-interactive
