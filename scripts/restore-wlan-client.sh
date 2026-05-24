#!/bin/bash
# Reconnect wlan0 (STA). Use --recover after AP off to reset the radio.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/wlan-concurrent.sh
source "${SCRIPT_DIR}/wlan-concurrent.sh"

recover=""
[[ "${1:-}" == --recover || "${1:-}" == recover ]] && recover=recover

wlan_connect_client "$recover"
