#!/bin/bash
# Stop AP services and remove uap0 (video services stop separately — fast).

set -euo pipefail

AP="${AP:-uap0}"

echo "[drone-hotspot] Stopping dnsmasq and hostapd..."
systemctl stop --no-block gcs-video-rtsp.service gcs-video-udp-relay.service 2>/dev/null || true
pkill -9 -f '[f]fmpeg.*rtsp.*8554' 2>/dev/null || true
pkill -9 -f '[m]ediamtx /run/mediamtx-gcs' 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
systemctl stop hostapd 2>/dev/null || true
pkill -9 hostapd 2>/dev/null || true
pkill -9 dnsmasq 2>/dev/null || true

if ip link show "$AP" &>/dev/null; then
    echo "[drone-hotspot] Removing $AP"
    iw dev "$AP" del 2>/dev/null || true
fi

if command -v nmcli >/dev/null 2>&1 && ip link show wlan0 &>/dev/null; then
    nmcli device set wlan0 managed yes 2>/dev/null || true
    ip link set wlan0 up 2>/dev/null || true
fi

echo "[drone-hotspot] Stopped"
