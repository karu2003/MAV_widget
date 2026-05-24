#!/bin/bash
# Restart MAVProxy + RTSP after uap0 is up (called from drone-hotspot).

set -euo pipefail

GCS_USER="${GCS_USER:-ubuntu}"
UID_NUM="$(id -u "$GCS_USER" 2>/dev/null || echo 1000)"
RUNTIME="/run/user/${UID_NUM}"

log() { echo "[ap-streaming] $*"; }

if ip link show uap0 &>/dev/null; then
    sysctl -w net.ipv4.conf.uap0.rp_filter=0 >/dev/null 2>&1 || true
fi

if systemctl is-enabled gcs-video-rtsp.service &>/dev/null; then
    systemctl restart gcs-video-rtsp.service 2>/dev/null || systemctl start gcs-video-rtsp.service 2>/dev/null || true
elif [[ -x /usr/local/bin/start-video-rtsp.sh ]]; then
    pkill -f '[f]fmpeg.*rtsp.*8554' 2>/dev/null || true
    nohup /usr/local/bin/start-video-rtsp.sh >>/var/log/gcs-video-rtsp.log 2>&1 &
fi

if [[ -d "$RUNTIME" ]] && sudo -u "$GCS_USER" \
    XDG_RUNTIME_DIR="$RUNTIME" DBUS_SESSION_BUS_ADDRESS="unix:path=${RUNTIME}/bus" \
    systemctl --user is-active --quiet mavproxy-gcs.service 2>/dev/null; then
    log "Restarting mavproxy-gcs (AP MAVLink outputs)"
    sudo -u "$GCS_USER" \
        XDG_RUNTIME_DIR="$RUNTIME" DBUS_SESSION_BUS_ADDRESS="unix:path=${RUNTIME}/bus" \
        systemctl --user restart mavproxy-gcs.service || log "WARN: mavproxy restart failed"
else
    log "mavproxy-gcs not active (skip)"
fi

log "Done"
