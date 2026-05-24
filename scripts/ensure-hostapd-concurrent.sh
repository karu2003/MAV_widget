#!/bin/bash
# hostapd options for concurrent STA+AP (same channel). Removes invalid keys.

set -euo pipefail

HOSTAPD_CONF="${HOSTAPD_CONF:-/etc/hostapd/drone-hotspot.conf}"

if [[ ! -f "$HOSTAPD_CONF" ]]; then
    echo "No $HOSTAPD_CONF — skip"
    exit 0
fi

# noscan is not valid in hostapd 2.10 on this platform — breaks AP start entirely.
sed -i '/^noscan=/d' "$HOSTAPD_CONF"

if ! grep -q '^beacon_int=' "$HOSTAPD_CONF"; then
    echo 'beacon_int=100' >>"$HOSTAPD_CONF"
    echo "Added beacon_int=100"
fi

echo "hostapd concurrent options OK: $HOSTAPD_CONF"
