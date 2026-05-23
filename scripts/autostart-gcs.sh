#!/bin/bash
# Post-login autostart: MAVProxy only (AP is started by drone-hotspot.service).

set -euo pipefail

if ! systemctl is-active --quiet hostapd; then
    echo "[gcs-autostart] hostapd not active, skipping MAVProxy"
    exit 0
fi

if pgrep -f "mavproxy.py" >/dev/null; then
    echo "[gcs-autostart] MAVProxy already running"
    exit 0
fi

echo "[gcs-autostart] Configuring network for MAVLink..."
sudo sysctl -w net.ipv4.conf.all.rp_filter=0
sudo sysctl -w net.ipv4.conf.eth0.rp_filter=0

echo "[gcs-autostart] Starting MAVProxy..."
sudo -u ubuntu HOME=/home/ubuntu python3 /home/ubuntu/.local/bin/mavproxy.py \
    --master=udp:192.168.53.1:14550 \
    --out=udp:0.0.0.0:14551 \
    --out=udp:192.168.54.255:14550 \
    --daemon

echo "[gcs-autostart] MAVProxy started"
