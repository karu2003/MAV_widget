#!/bin/bash
# Safe Wi-Fi recovery after AP: clean duplicate NM profiles and reconnect.
# Does not edit, delete, or recreate saved Wi-Fi profiles.

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

exec "${SCRIPT_DIR}/restore-wlan-client.sh" --recover
