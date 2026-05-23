#!/bin/bash
# Wait until MAVProxy forwards telemetry to the widget port.

set -euo pipefail

WIDGET_PORT="${1:-14552}"
MAX_WAIT_S="${2:-90}"

echo "[wait-mavlink] Waiting for telemetry on UDP ${WIDGET_PORT} (max ${MAX_WAIT_S}s)..."

for ((elapsed = 0; elapsed < MAX_WAIT_S; elapsed += 2)); do
    if python3 - <<PY
from pymavlink import mavutil
m = mavutil.mavlink_connection("udp:127.0.0.1:${WIDGET_PORT}")
msg = m.wait_heartbeat(timeout=2)
if msg and msg.get_srcSystem() > 0:
    raise SystemExit(0)
raise SystemExit(1)
PY
    then
        echo "[wait-mavlink] Link OK (${elapsed}s)"
        exit 0
    fi
    sleep 2
done

echo "[wait-mavlink] Timeout — widget will retry in background"
exit 0
