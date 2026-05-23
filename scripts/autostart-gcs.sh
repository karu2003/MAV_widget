#!/bin/bash
# Legacy / manual MAVProxy start — prefer: systemctl --user start mavproxy-gcs.service

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if systemctl --user is-active --quiet mavproxy-gcs.service 2>/dev/null; then
    echo "[gcs-autostart] mavproxy-gcs.service already active"
    exit 0
fi

if pgrep -f '[m]avproxy\.py' >/dev/null 2>&1; then
    echo "[gcs-autostart] MAVProxy already running"
    exit 0
fi

if command -v systemctl >/dev/null && systemctl --user list-unit-files mavproxy-gcs.service >/dev/null 2>&1; then
    echo "[gcs-autostart] Starting mavproxy-gcs.service..."
    systemctl --user start mavproxy-gcs.service
    exit 0
fi

echo "[gcs-autostart] Starting MAVProxy (standalone)..."
"${SCRIPT_DIR}/wait_gcs_ready.sh" hostapd 20
"${SCRIPT_DIR}/start_mavproxy.sh"
"${SCRIPT_DIR}/wait_gcs_ready.sh" mavproxy 10
echo "[gcs-autostart] MAVProxy started"
