#!/bin/bash
# Restart MAVProxy + ensure video services run (non-blocking — safe at boot).

set -euo pipefail

GCS_USER="${GCS_USER:-ubuntu}"
UID_NUM="$(id -u "$GCS_USER" 2>/dev/null || echo 1000)"
RUNTIME="/run/user/${UID_NUM}"

log() { echo "[ap-streaming] $*"; }

if ip link show uap0 &>/dev/null; then
    sysctl -w net.ipv4.conf.uap0.rp_filter=0 >/dev/null 2>&1 || true
fi

# Do not "restart" here — systemctl restart can block drone-hotspot for ~90s at boot.
systemctl start --no-block gcs-video-udp-relay.service 2>/dev/null || true
systemctl start --no-block gcs-video-rtsp.service 2>/dev/null || true

if [[ -d "$RUNTIME" ]] && sudo -u "$GCS_USER" \
    XDG_RUNTIME_DIR="$RUNTIME" DBUS_SESSION_BUS_ADDRESS="unix:path=${RUNTIME}/bus" \
    systemctl --user is-active --quiet mavproxy-gcs.service 2>/dev/null; then
    log "Restarting mavproxy-gcs (AP MAVLink outputs)"
    sudo -u "$GCS_USER" \
        XDG_RUNTIME_DIR="$RUNTIME" DBUS_SESSION_BUS_ADDRESS="unix:path=${RUNTIME}/bus" \
        systemctl --user restart mavproxy-gcs.service &
    # Re-bind the unicast fan-out relay to AP_IP after the AP interface returns.
    sudo -u "$GCS_USER" \
        XDG_RUNTIME_DIR="$RUNTIME" DBUS_SESSION_BUS_ADDRESS="unix:path=${RUNTIME}/bus" \
        systemctl --user restart mav-ap-fanout.service 2>/dev/null &
else
    log "mavproxy-gcs not active yet (skip)"
fi

log "Done"
