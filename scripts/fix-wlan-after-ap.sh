#!/bin/bash
# Restore wlan0 after AP off (radio reset + reconnect). Run: sudo fix-wlan-after-ap.sh

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/restore-wlan-client.sh" --recover
