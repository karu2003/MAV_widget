#!/bin/bash
# Reset NM Wi‑Fi profiles after AP (clear channel/band pins) and reconnect.

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/wlan-concurrent.sh
source "${SCRIPT_DIR}/wlan-concurrent.sh"

if [[ -x /usr/local/bin/cleanup-nm-wifi-duplicates.sh ]]; then
    /usr/local/bin/cleanup-nm-wifi-duplicates.sh
elif [[ -x "${SCRIPT_DIR}/cleanup-nm-wifi-duplicates.sh" ]]; then
    "${SCRIPT_DIR}/cleanup-nm-wifi-duplicates.sh"
fi

load_gcs_streaming_conf
profile=""
if [[ -f /var/lib/gcs-ap/wlan-sta.state ]]; then
    profile="$(grep -E '^profile=' /var/lib/gcs-ap/wlan-sta.state | cut -d= -f2-)"
fi
[[ -z "$profile" && -n "${GCS_WLAN_CONNECTION:-}" ]] && profile="$GCS_WLAN_CONNECTION"

if [[ -n "$profile" ]] && nmcli -t -f NAME connection show | grep -Fxq "$profile"; then
    if "${SCRIPT_DIR}/repair-wifi-profile.sh" "$profile"; then
        exit 0
    fi
fi

exec "${SCRIPT_DIR}/restore-wlan-client.sh" --recover
