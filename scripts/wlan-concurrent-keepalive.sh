#!/bin/bash
# Keep wlan0 client connected while AP (uap0) runs — true concurrent STA+AP.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/wlan-concurrent.sh
source "${SCRIPT_DIR}/wlan-concurrent.sh"

if [[ -f /var/lib/gcs-ap/manual-off ]]; then
    exit 0
fi

if ! wlan_is_ap_active; then
    exit 0
fi

if [[ "$(wlan_ap_mode)" != "concurrent" ]]; then
    wlan_log "Keepalive: AP mode is $(wlan_ap_mode), not concurrent — skipping wlan0"
    exit 0
fi

if wlan_is_connected; then
    exit 0
fi

# wlan0 is connecting but not yet associated — don't interrupt in-progress attempt.
if wlan_sta_is_busy; then
    wlan_log "Keepalive: wlan0 is connecting — waiting for next tick"
    exit 0
fi

# Skip if a stop/start operation is holding the radio lock.
WLAN_LOCK="${WLAN_LOCK:-/run/gcs-wlan.lock}"
mkdir -p "$(dirname "$WLAN_LOCK")"
exec 9>"$WLAN_LOCK"
if ! flock -n 9; then
    wlan_log "Keepalive: radio lock busy (stop/start in progress) — skipping"
    exit 0
fi

wlan_log "Keepalive: AP up, wlan0 down — reconnecting (concurrent mode)"
# Keepalive must be quick and non-invasive. If no same-channel SSID is visible,
# exit and let the next timer tick try again instead of holding wlan0 in NM loops.
timeout 45 bash -c 'source "$1"; wlan_connect_client' _ "${SCRIPT_DIR}/wlan-concurrent.sh" \
    || wlan_log "Keepalive: reconnect skipped/failed"
