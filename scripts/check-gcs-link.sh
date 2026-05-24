#!/bin/bash
# GCS link diagnostics: wlan0 client + MAVProxy + widget port.

set -euo pipefail

CONF="${GCS_STREAMING_CONF:-/etc/default/gcs-ap-streaming}"
[[ -f "$CONF" ]] && # shellcheck disable=SC1090
source "$CONF"

ok() { echo "  OK   $*"; }
fail() { echo "  FAIL $*"; }

echo "=== GCS link check ==="
echo ""

# Wi-Fi client (internet uplink on wlan0)
if ip link show wlan0 &>/dev/null; then
    state="$(nmcli -t -f STATE device show wlan0 2>/dev/null | head -1 || echo unknown)"
    conn="$(nmcli -t -f CONNECTION device show wlan0 2>/dev/null | head -1 || true)"
    if [[ "$state" == "connected" && -n "$conn" ]]; then
        ok "wlan0 connected ($conn)"
        ip -br addr show wlan0 | awk '{print "       "$0}'
    else
        fail "wlan0 not connected (state=$state)"
    ap_ch=""
    if ip link show uap0 &>/dev/null 2>/dev/null; then
        ap_ch="$(iw dev uap0 info 2>/dev/null | awk '/channel/ {print $2; exit}')"
        [[ -n "$ap_ch" ]] && echo "       AP channel ${ap_ch} — client must use same channel"
    fi
    echo "       sudo restore-wlan-client.sh   # or tray: Reconnect Wi‑Fi client"
        nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="802-11-wireless"{print "       profile: "$1}'
        if [[ -n "$ap_ch" ]]; then
            echo "       Networks visible on wlan0 (channel ${ap_ch} only while AP is on):"
            nmcli -f IN-USE,SSID,CHAN,SIGNAL device wifi list ifname wlan0 2>/dev/null \
                | head -6 | sed 's/^/         /' || true
        fi
    fi
else
    fail "wlan0 missing"
fi
echo ""

# AP (uap0)
if systemctl is-active --quiet hostapd 2>/dev/null && ip link show uap0 &>/dev/null; then
    ssid="$(grep -E '^ssid=' /etc/hostapd/drone-hotspot.conf 2>/dev/null | cut -d= -f2- || echo '?')"
    ap_ch="$(iw dev uap0 info 2>/dev/null | awk '/channel/ {print $2; exit}')"
    ok "AP active ($ssid on uap0, channel ${ap_ch:-?})"
else
    echo "  --   AP off (uap0/hostapd inactive)"
fi
echo ""

# MAVProxy
if pgrep -f '[m]avproxy\.py' >/dev/null; then
    ok "MAVProxy running (pid $(pgrep -f '[m]avproxy\.py' | head -1))"
else
    fail "MAVProxy not running — systemctl --user start mavproxy-gcs"
fi

if ss -ulnp 2>/dev/null | grep -q '192.168.53.1:14550'; then
    ok "MAVProxy master udpin 192.168.53.1:14550"
else
    fail "MAVProxy not listening on 192.168.53.1:14550"
fi

if ss -ulnp 2>/dev/null | grep -q '127.0.0.1:14552'; then
    ok "MAVProxy out 127.0.0.1:14552 (widget)"
else
    fail "Nothing on 127.0.0.1:14552 — widget will show NO LINK"
fi
echo ""

# Drone heartbeat on widget port
if python3 - <<'PY' 2>/dev/null
import sys, time
from pymavlink import mavutil
m = mavutil.mavlink_connection("udp:127.0.0.1:14552")
msg = m.wait_heartbeat(timeout=3)
sys.exit(0 if msg and msg.get_srcSystem() > 0 else 1)
PY
then
    ok "Vehicle heartbeat on widget port 14552"
else
    fail "No drone heartbeat on 14552 (MAVProxy log: link 1 down?)"
    echo "       Drone must send UDP to 192.168.53.1:14550 on eth0 (radio port)"
    echo "       Check: tail ~/.local/state/mav-gcs/mavproxy-gcs.log"
fi
echo ""

# Widget service
if systemctl --user is-active --quiet mav-widget.service 2>/dev/null; then
    ok "mav-widget.service active"
else
    fail "mav-widget.service not active"
fi

echo "=== done ==="
