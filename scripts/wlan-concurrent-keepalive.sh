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

if wlan_is_connected; then
    exit 0
fi

wlan_log "Keepalive: AP up, wlan0 down — reconnecting (concurrent mode)"
wlan_connect_client
