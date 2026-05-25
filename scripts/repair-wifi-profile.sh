#!/bin/bash
# Safely repair an NM Wi-Fi profile. It never deletes the original profile until
# a temporary replacement has connected successfully.

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

PROFILE="${1:?Usage: repair-wifi-profile.sh PROFILE [BSSID]}"
BSSID="${2:-}"
WLAN="${WLAN:-wlan0}"
TMP_PROFILE="${PROFILE}.repair-test"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/wlan-concurrent.sh
source "${SCRIPT_DIR}/wlan-concurrent.sh"

if ! nmcli -t -f NAME connection show | grep -Fxq "$PROFILE"; then
    echo "[repair-wifi] No such profile: ${PROFILE}" >&2
    exit 1
fi

ssid="$(nmcli -g 802-11-wireless.ssid connection show "$PROFILE")"
psk="$(nmcli -s -g 802-11-wireless-security.psk connection show "$PROFILE")"
auto="$(nmcli -g connection.autoconnect connection show "$PROFILE")"
prio="$(nmcli -g connection.autoconnect-priority connection show "$PROFILE" 2>/dev/null || echo 0)"

if [[ -z "$ssid" || "$ssid" == "--" ]]; then
    echo "[repair-wifi] Missing SSID on ${PROFILE}" >&2
    exit 1
fi
if [[ -z "$psk" || "$psk" == "--" ]]; then
    echo "[repair-wifi] PSK not stored on ${PROFILE}; use nmcli device wifi connect manually" >&2
    exit 1
fi

echo "[repair-wifi] Testing replacement for ${PROFILE} (${ssid}); original profile is kept until success"
nmcli connection down "$TMP_PROFILE" 2>/dev/null || true
nmcli connection delete "$TMP_PROFILE" 2>/dev/null || true

wlan_recover_radio

wlan_prepare_nm
if ! wlan_wait_for_ssid "$ssid"; then
    echo "[repair-wifi] WARNING: ${ssid} not visible in scan" >&2
fi

if [[ -z "$BSSID" ]]; then
    bssid="$(wlan_bssid_for_ssid "$ssid")"
else
    bssid="$BSSID"
fi

nmcli connection add type wifi ifname "$WLAN" con-name "$TMP_PROFILE" ssid "$ssid" \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk "$psk" \
    connection.autoconnect no >/dev/null

args=(connection up "$TMP_PROFILE" ifname "$WLAN")
[[ -n "$bssid" ]] && args+=(ap "$bssid")

connected=false
for attempt in 1 2 3; do
    wlan_fix_radio_power
    echo "[repair-wifi] Connect attempt ${attempt}/3: ${ssid}${bssid:+ @ ${bssid}}..."
    if nmcli -w 60 "${args[@]}"; then
        connected=true
        break
    fi
    nmcli device disconnect "$WLAN" 2>/dev/null || true
    sleep 5
    bssid="$(wlan_bssid_for_ssid "$ssid")"
    args=(connection up "$TMP_PROFILE" ifname "$WLAN")
    [[ -n "$bssid" ]] && args+=(ap "$bssid")
done

if [[ "$connected" != true ]]; then
    tp="$(iw dev "$WLAN" info 2>/dev/null | awk '/txpower/ {print $2; exit}')"
    nmcli connection down "$TMP_PROFILE" 2>/dev/null || true
    nmcli connection delete "$TMP_PROFILE" 2>/dev/null || true
    echo "[repair-wifi] FAILED; kept original profile ${PROFILE}" >&2
    echo "[repair-wifi] wlan0 txpower=${tp:-?} dBm (auth timeout often means radio/driver is stuck, not profile damage)" >&2
    exit 1
fi

nmcli connection down "$PROFILE" 2>/dev/null || true
nmcli connection delete "$PROFILE"
nmcli connection modify "$TMP_PROFILE" connection.id "$PROFILE" connection.interface-name "$WLAN" 2>/dev/null || true
if [[ "$auto" == yes ]]; then
    nmcli connection modify "$PROFILE" connection.autoconnect yes \
        connection.autoconnect-priority "$prio" 2>/dev/null || true
fi
wlan_save_sta_state "$PROFILE"

echo "[repair-wifi] Connected: ${PROFILE} ch=$(iw dev "$WLAN" info 2>/dev/null | awk '/channel/ {print $2; exit}')"
