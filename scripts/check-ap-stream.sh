#!/bin/bash
# Verify MAVLink broadcast and RTSP for AP clients.

set -euo pipefail

CONF="${GCS_STREAMING_CONF:-/etc/default/gcs-ap-streaming}"
[[ -f "$CONF" ]] && # shellcheck disable=SC1090
source "$CONF"

AP_IP="${AP_IP:-192.168.54.1}"
MAV_AP_BCAST_PORT="${MAV_AP_BCAST_PORT:-14550}"
RTSP_PORT="${RTSP_PORT:-8554}"
RTSP_PATH="${RTSP_PATH:-/stream}"

ok() { echo "  OK  $*"; }
fail() { echo "  FAIL $*"; }

echo "=== AP streaming check ==="
echo "AP: ${AP_IP}  MAV UDP: ${MAV_AP_BCAST_PORT}  RTSP: rtsp://${AP_IP}:${RTSP_PORT}${RTSP_PATH}"
echo ""

if ip link show uap0 &>/dev/null && ip -4 addr show dev uap0 2>/dev/null | grep -q "${AP_IP}"; then
    ok "uap0 up with ${AP_IP}"
else
    fail "uap0 / ${AP_IP} — start AP: toggle-ap.sh or systemctl start drone-hotspot"
fi

if systemctl is-active --quiet hostapd 2>/dev/null; then
    ok "hostapd active"
else
    fail "hostapd not active"
fi

if pgrep -f '[m]avproxy\.py' >/dev/null; then
    ok "MAVProxy running"
    if pgrep -af '[m]avproxy\.py' | grep -q 'udpbcast:192.168.54'; then
        ok "MAVProxy udpbcast -> AP subnet"
    else
        fail "MAVProxy missing --out=udpbcast:192.168.54.255:..."
    fi
    if pgrep -af '[m]avproxy\.py' | grep -q 'udpin:192.168.54'; then
        ok "MAVProxy udpin on AP (client uplink)"
    else
        fail "MAVProxy missing --out=udpin:192.168.54.1:..."
    fi
else
    fail "MAVProxy not running (systemctl --user start mavproxy-gcs)"
fi

if systemctl is-active --quiet gcs-video-udp-relay.service 2>/dev/null || pgrep -f '[v]ideo-udp-relay.py' >/dev/null; then
    ok "UDP video relay (${VIDEO_IFACE:-eth0}:5600 -> 127.0.0.1:5601)"
else
    fail "video-udp-relay not running (QGC uses :5600 on GCS)"
fi

if pgrep -f '[f]fmpeg.*rtsp.*8554' >/dev/null; then
    ok "ffmpeg publishing RTP -> RTSP"
elif pgrep -f '[f]fmpeg.*8554' >/dev/null; then
    ok "ffmpeg RTSP publisher"
else
    fail "ffmpeg not publishing (journalctl -u gcs-video-rtsp -n 10)"
fi

if pgrep -f '[m]ediamtx /run/mediamtx-gcs' >/dev/null; then
    ok "RTSP server (MediaMTX publisher)"
fi

if ss -ulnp 2>/dev/null | grep -q ":${MAV_AP_BCAST_PORT}"; then
    ok "UDP :${MAV_AP_BCAST_PORT} in use (expected)"
else
    echo "  WARN no listener on UDP ${MAV_AP_BCAST_PORT} (broadcast may still work)"
fi

if ss -ltnp 2>/dev/null | grep -q ":${RTSP_PORT}"; then
    ok "TCP :${RTSP_PORT} listening"
elif ss -ltnp 2>/dev/null | grep -q "${AP_IP}:${RTSP_PORT}"; then
    ok "TCP ${AP_IP}:${RTSP_PORT} listening"
else
    fail "RTSP port ${RTSP_PORT} not listening — run: sudo install-mediamtx.sh && sudo systemctl restart gcs-video-rtsp"
fi

if pgrep -f '[m]ediamtx' >/dev/null; then
    if systemctl is-failed --quiet gcs-video-rtsp.service 2>/dev/null; then
        fail "gcs-video-rtsp in failed state (journalctl -u gcs-video-rtsp -n 20)"
    fi
elif journalctl -u gcs-video-rtsp -n 5 --no-pager 2>/dev/null | grep -qE 'rtpSDP|Invalid data found'; then
    echo "  WARN: update config — sudo cp .../mediamtx-gcs.yml /etc/mediamtx-gcs.yml.template && sudo systemctl restart gcs-video-rtsp"
fi

echo ""
echo "QGC on phone/tablet (Wi-Fi CaimanHS):"
echo "  MAVLink: UDP, listen port ${MAV_AP_BCAST_PORT}  (or target ${AP_IP}:${MAV_AP_BCAST_PORT})"
echo "  Video:   RTSP URL rtsp://${AP_IP}:${RTSP_PORT}${RTSP_PATH}"
echo "  Disable QGC AutoConnect UDP on 14550 if also using wired GCS."
