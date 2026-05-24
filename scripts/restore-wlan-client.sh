#!/bin/bash
# Reconnect wlan0 as Wi‑Fi client while uap0 AP stays up (concurrent STA+AP).

set -euo pipefail

WLAN="${WLAN:-wlan0}"
AP="${AP:-uap0}"
HOSTAPD_CONF="${HOSTAPD_CONF:-/etc/hostapd/drone-hotspot.conf}"
CONF="${GCS_STREAMING_CONF:-/etc/default/gcs-ap-streaming}"
[[ -f "$CONF" ]] && # shellcheck disable=SC1090
source "$CONF"

log() { echo "[restore-wlan] $*"; }

if ! command -v nmcli >/dev/null 2>&1; then
    log "nmcli not found — skip"
    exit 0
fi

if ! ip link show "$WLAN" &>/dev/null; then
    log "No $WLAN — skip"
    exit 0
fi

AP_SSID="$(grep -E '^ssid=' "$HOSTAPD_CONF" 2>/dev/null | cut -d= -f2- || true)"

try_connect() {
    local name="$1"
    local err
    err="$(nmcli connection up "$name" ifname "$WLAN" 2>&1)" && return 0
    log "  $name: $err"
    return 1
}

nmcli radio wifi on 2>/dev/null || true
nmcli device set "$WLAN" managed yes 2>/dev/null || true
if ip link show "$AP" &>/dev/null; then
    nmcli device set "$AP" managed no 2>/dev/null || true
fi
ip link set "$WLAN" up 2>/dev/null || true
sleep 3

if [[ -n "${GCS_WLAN_CONNECTION:-}" ]]; then
    for _ in 1 2 3; do
        if try_connect "${GCS_WLAN_CONNECTION}"; then
            log "Connected $WLAN via ${GCS_WLAN_CONNECTION}"
            exit 0
        fi
        sleep 2
    done
    log "WARN: profile ${GCS_WLAN_CONNECTION} failed after retries"
fi

while IFS= read -r line; do
    name="${line%%:*}"
    [[ -z "$name" ]] && continue
    [[ "$name" == "$AP_SSID" ]] && continue
    [[ "$name" == "Hotspot" ]] && continue
    [[ "$name" == "CaimanHS" ]] && continue
    if try_connect "$name"; then
        log "Connected $WLAN via $name"
        exit 0
    fi
done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1}')

log "WARN: $WLAN still disconnected"
log "Set GCS_WLAN_CONNECTION=ProfileName in $CONF (nmcli connection show)"
exit 1
