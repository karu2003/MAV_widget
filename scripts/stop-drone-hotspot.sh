#!/bin/bash
# Stop AP services and remove uap0.

set -euo pipefail

AP="${AP:-uap0}"

echo "[drone-hotspot] Stopping dnsmasq and hostapd..."
systemctl stop dnsmasq 2>/dev/null || true
systemctl stop hostapd 2>/dev/null || true

if ip link show "$AP" &>/dev/null; then
    echo "[drone-hotspot] Removing $AP"
    iw dev "$AP" del 2>/dev/null || true
fi

echo "[drone-hotspot] Stopped"
