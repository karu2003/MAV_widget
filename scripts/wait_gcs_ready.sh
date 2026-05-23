#!/bin/bash
# Fast readiness checks for GCS boot (hostapd, MAVProxy process, optional heartbeat).

set -euo pipefail

usage() {
    echo "Usage: $0 hostapd [max_sec]" >&2
    echo "       $0 mavproxy [max_sec]" >&2
    echo "       $0 heartbeat <port> [max_sec]" >&2
    exit 2
}

wait_hostapd() {
    local max="${1:-15}"
    local start=$SECONDS
    while (( SECONDS - start < max )); do
        if systemctl is-active --quiet hostapd 2>/dev/null; then
            echo "[wait-gcs] hostapd ready ($((SECONDS - start))s)"
            return 0
        fi
        sleep 0.5
    done
    echo "[wait-gcs] hostapd timeout (${max}s)" >&2
    return 1
}

wait_mavproxy() {
    local max="${1:-15}"
    local start=$SECONDS
    while (( SECONDS - start < max )); do
        if pgrep -f '[m]avproxy\.py' >/dev/null 2>&1; then
            echo "[wait-gcs] MAVProxy ready ($((SECONDS - start))s)"
            return 0
        fi
        sleep 0.2
    done
    echo "[wait-gcs] MAVProxy timeout (${max}s)" >&2
    return 1
}

wait_heartbeat() {
    local port="${1:?port required}"
    local max="${2:-30}"
  python3 - "$port" "$max" <<'PY'
import sys, time
from pymavlink import mavutil

port = int(sys.argv[1])
timeout = float(sys.argv[2])
deadline = time.time() + timeout
conn = mavutil.mavlink_connection(f"udp:127.0.0.1:{port}")
while time.time() < deadline:
    msg = conn.wait_heartbeat(timeout=0.25)
    if msg and msg.get_srcSystem() > 0:
        raise SystemExit(0)
    time.sleep(0.15)
raise SystemExit(1)
PY
}

case "${1:-}" in
    hostapd)
        wait_hostapd "${2:-15}"
        ;;
    mavproxy)
        wait_mavproxy "${2:-15}"
        ;;
    heartbeat)
        [[ $# -ge 2 ]] || usage
        if wait_heartbeat "$2" "${3:-30}"; then
            echo "[wait-gcs] heartbeat on port $2"
        else
            echo "[wait-gcs] heartbeat timeout on port $2 (continuing)" >&2
            exit 0
        fi
        ;;
    *)
        usage
        ;;
esac
