#!/bin/bash
# Start MAVProxy for GCS (foreground — managed by systemd).

set -euo pipefail

CONF="${GCS_STREAMING_CONF:-/etc/default/gcs-ap-streaming}"
if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CONF"
fi

AP_IP="${AP_IP:-192.168.54.1}"
MAV_AP_IN_PORT="${MAV_AP_IN_PORT:-14550}"
# Internal loopback port that feeds the unicast fan-out relay (mav-ap-fanout.py).
MAV_AP_FANOUT_PORT="${MAV_AP_FANOUT_PORT:-14545}"

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

# Loose reverse-path filter on the radio link so drone packets are accepted
# even when another interface shares the 192.168.53.0/24 subnet.
RADIO_IF="${RADIO_IF:-eth0}"
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w "net.ipv4.conf.${RADIO_IF}.rp_filter=0" >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.eth0.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.uap0.rp_filter=0 >/dev/null 2>&1 || true

# Local consumers (loopback) + a feed for the AP unicast fan-out relay.
#   14550 -> local QGroundControl (auto-connect UDP listens on 0.0.0.0:14550)
#   14551 -> spare local link
#   14552 -> MAV_Widget
#   14545 -> mav-ap-fanout.py, which unicasts to each phone on the AP
#            (udpbcast is unreliable: pymavlink latches onto the first
#             responder and Wi-Fi broadcast is often dropped by Android)
# AP client uplink (phone -> drone) is handled by the fan-out relay, which
# owns ${AP_IP}:${MAV_AP_IN_PORT} and forwards phone packets back on 14545.
MAV_OUTS=(
    --out="udp:127.0.0.1:14550"
    --out=127.0.0.1:14551
    --out=127.0.0.1:14552
    --out="udp:127.0.0.1:${MAV_AP_FANOUT_PORT}"
)

echo "[mavproxy] Starting (foreground, force-connected, AP unicast fan-out :${MAV_AP_FANOUT_PORT})..."
exec python3 "$MAVPROXY" \
    --master=udpin:192.168.53.1:14550 \
    "${MAV_OUTS[@]}" \
    --nowait \
    --force-connected \
    --non-interactive
