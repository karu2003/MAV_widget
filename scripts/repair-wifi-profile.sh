#!/bin/bash
# Recreate an NM Wi‑Fi profile (clears stale seen-bssids / channel pins NM 1.36 keeps).

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

PROFILE="${1:?Usage: repair-wifi-profile.sh PROFILE [BSSID]}"
BSSID="${2:-}"
WLAN="${WLAN:-wlan0}"

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

echo "[repair-wifi] Recreating ${PROFILE} (${ssid})"
nmcli connection down "$PROFILE" 2>/dev/null || true
nmcli connection delete "$PROFILE"

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

args=(device wifi connect "$ssid" password "$psk" ifname "$WLAN")
[[ -n "$bssid" ]] && args+=(bssid "$bssid")

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
    args=(device wifi connect "$ssid" password "$psk" ifname "$WLAN")
    [[ -n "$bssid" ]] && args+=(bssid "$bssid")
done

if [[ "$connected" != true ]]; then
    tp="$(iw dev "$WLAN" info 2>/dev/null | awk '/txpower/ {print $2; exit}')"
    echo "[repair-wifi] FAILED (wlan0 txpower=${tp:-?} dBm; auth timeout often means txpower stuck at ~3)" >&2
    exit 1
fi

new_profile="$(nmcli -t -f CONNECTION device show "$WLAN" 2>/dev/null | head -1)"
if [[ -z "$new_profile" || "$new_profile" == "--" ]]; then
    new_profile="$(nmcli -t -f NAME,802-11-wireless.ssid connection show \
        | awk -F: -v s="$ssid" '$2==s {print $1; exit}')"
fi

if [[ -n "$new_profile" && "$new_profile" != "--" ]]; then
    if [[ "$new_profile" != "$PROFILE" ]]; then
        nmcli connection modify "$new_profile" connection.id "$PROFILE" 2>/dev/null \
            || new_profile="$PROFILE"
    fi
    nmcli connection modify "$PROFILE" connection.interface-name "$WLAN" 2>/dev/null || true
    if [[ "$auto" == yes ]]; then
        nmcli connection modify "$PROFILE" connection.autoconnect yes \
            connection.autoconnect-priority "$prio" 2>/dev/null || true
    fi
    wlan_save_sta_state "$PROFILE"
fi

echo "[repair-wifi] Connected: ${PROFILE} ch=$(iw dev "$WLAN" info 2>/dev/null | awk '/channel/ {print $2; exit}')"
