#!/bin/bash
# Helpers: concurrent wlan0 (STA) + uap0 (AP) on one radio (#channels <= 1).

set -euo pipefail

WLAN="${WLAN:-wlan0}"
AP="${AP:-uap0}"
HOSTAPD_CONF="${HOSTAPD_CONF:-/etc/hostapd/drone-hotspot.conf}"
GCS_AP_STATE="${GCS_AP_STATE:-/var/lib/gcs-ap}"
STA_STATE_FILE="${GCS_AP_STATE}/wlan-sta.state"

load_gcs_streaming_conf() {
    local conf="${GCS_STREAMING_CONF:-/etc/default/gcs-ap-streaming}"
    if [[ -f "$conf" ]]; then
        # shellcheck disable=SC1090
        source "$conf"
    fi
}

wlan_log() { echo "[wlan-concurrent] $*"; }

wlan_ap_ssid() {
    grep -E '^ssid=' "$HOSTAPD_CONF" 2>/dev/null | cut -d= -f2- || true
}

wlan_is_ap_active() {
    ip link show "$AP" &>/dev/null && systemctl is-active --quiet hostapd 2>/dev/null
}

# Read channel from wlan0 (connected or cached).
wlan_ap_channel() {
    local ch
    ch="$(iw dev "$WLAN" info 2>/dev/null | awk '/channel/ {print $2; exit}')"
    if [[ -n "$ch" ]]; then
        echo "$ch"
        return 0
    fi
    if [[ -f "$STA_STATE_FILE" ]]; then
        ch="$(grep -E '^channel=' "$STA_STATE_FILE" 2>/dev/null | cut -d= -f2)"
        if [[ -n "$ch" ]]; then
            echo "$ch"
            return 0
        fi
    fi
    ch="$(grep -E '^channel=' "$HOSTAPD_CONF" 2>/dev/null | cut -d= -f2)"
    if [[ -n "$ch" ]]; then
        echo "$ch"
        return 0
    fi
    echo "6"
}

wlan_band_for_channel() {
    local ch="$1"
    if [[ "$ch" -le 14 ]]; then
        echo "bg"
    else
        echo "a"
    fi
}

wlan_hw_mode_for_channel() {
    local ch="$1"
    if [[ "$ch" -le 14 ]]; then
        echo "g"
    else
        echo "a"
    fi
}

wlan_link_bssid() {
    iw dev "$WLAN" link 2>/dev/null | awk '/Connected to/ {print $3; exit}'
}

wlan_is_connected() {
    nmcli -t -f STATE device show "$WLAN" 2>/dev/null | head -1 | grep -qx connected
}

wlan_save_sta_state() {
    local profile="${1:-${GCS_WLAN_CONNECTION:-}}"
    local ch bssid ssid band hw
    mkdir -p "$GCS_AP_STATE"
    ch="$(iw dev "$WLAN" info 2>/dev/null | awk '/channel/ {print $2; exit}')"
    bssid="$(wlan_link_bssid)"
    ssid="$(iw dev "$WLAN" link 2>/dev/null | awk -F'ssid ' '/SSID:/ {print $2; exit}')"
    band="$(wlan_band_for_channel "${ch:-6}")"
    hw="$(wlan_hw_mode_for_channel "${ch:-6}")"
    {
        echo "profile=${profile}"
        echo "channel=${ch}"
        echo "band=${band}"
        echo "hw_mode=${hw}"
        echo "bssid=${bssid}"
        echo "ssid=${ssid}"
    } >"$STA_STATE_FILE"
    wlan_log "Saved STA: profile=${profile} ch=${ch} band=${band} ssid=${ssid}"
}

wlan_ensure_hostapd_concurrent_opts() {
    [[ -f "$HOSTAPD_CONF" ]] || return 0
    sed -i '/^noscan=/d' "$HOSTAPD_CONF"
    grep -q '^beacon_int=' "$HOSTAPD_CONF" || echo 'beacon_int=100' >>"$HOSTAPD_CONF"
}

wlan_apply_hostapd_rf() {
    local channel="${1:-$(wlan_ap_channel)}"
    local hw_mode band
    hw_mode="$(wlan_hw_mode_for_channel "$channel")"
    band="$(wlan_band_for_channel "$channel")"
    [[ -f "$HOSTAPD_CONF" ]] || return 0
    wlan_ensure_hostapd_concurrent_opts
    if grep -q '^hw_mode=' "$HOSTAPD_CONF"; then
        sed -i "s/^hw_mode=.*/hw_mode=${hw_mode}/" "$HOSTAPD_CONF"
    else
        echo "hw_mode=${hw_mode}" >>"$HOSTAPD_CONF"
    fi
    sed -i "s/^channel=.*/channel=${channel}/" "$HOSTAPD_CONF"
    wlan_log "hostapd hw_mode=${hw_mode} channel=${channel} (${band})"
}

wlan_pin_nm_connection() {
    local name="$1"
    local channel="$2"
    local band
    band="$(wlan_band_for_channel "$channel")"
    nmcli connection modify "$name" connection.interface-name "$WLAN" 2>/dev/null || true
    nmcli connection modify "$name" 802-11-wireless.band "$band" 2>/dev/null || true
    nmcli connection modify "$name" 802-11-wireless.channel "$channel" 2>/dev/null || true
}

wlan_unpin_nm_connection() {
    local name="$1"
    nmcli connection modify "$name" 802-11-wireless.channel 0 2>/dev/null || true
    nmcli connection modify "$name" 802-11-wireless.bssid "" 2>/dev/null || true
    nmcli connection modify "$name" 802-11-wireless.band "" 2>/dev/null || true
}

# Reset Wi‑Fi after AP mode (driver often needs this before STA works again).
wlan_recover_radio() {
    wlan_log "Resetting ${WLAN} radio after AP"

    systemctl stop hostapd dnsmasq 2>/dev/null || true
    if ip link show "$AP" &>/dev/null; then
        iw dev "$AP" del 2>/dev/null || true
        sleep 1
    fi

    nmcli device disconnect "$WLAN" 2>/dev/null || true
    nmcli device set "$WLAN" managed no 2>/dev/null || true
    ip link set "$WLAN" down 2>/dev/null || true
    sleep 1

    rfkill unblock wifi 2>/dev/null || true
    nmcli radio wifi off 2>/dev/null || true
    sleep 2
    nmcli radio wifi on 2>/dev/null || true
    sleep 2

    nmcli device set "$WLAN" managed yes 2>/dev/null || true
    iw dev "$WLAN" set type managed 2>/dev/null || true
    ip link set "$WLAN" up 2>/dev/null || true

    local i state
    for i in $(seq 1 15); do
        state="$(ip -br link show "$WLAN" 2>/dev/null | awk '{print $2}')"
        [[ "$state" == "UP" ]] && break
        sleep 1
    done

    nmcli device wifi rescan ifname "$WLAN" 2>/dev/null || true
    sleep 3

    wlan_log "  ${WLAN} state: $(ip -br link show "$WLAN" 2>/dev/null | awk '{print $2}')"
}

wlan_prepare_nm() {
    nmcli radio wifi on 2>/dev/null || true
    nmcli device set "$WLAN" managed yes 2>/dev/null || true
    if ip link show "$AP" &>/dev/null; then
        nmcli device set "$AP" managed no 2>/dev/null || true
    fi
    ip link set "$WLAN" up 2>/dev/null || true
}

wlan_profile_ssid() {
    nmcli -t -f 802-11-wireless.ssid connection show "$1" 2>/dev/null | head -1 | cut -d: -f2-
}

wlan_seen_has() {
    local seen="$1" name="$2"
    [[ "$seen" == "$name" || "$seen" == *"|${name}|"* || "$seen" == "${name}|"* || "$seen" == *"|${name}" ]]
}

wlan_seen_add() {
    local seen="$1" name="$2"
    if [[ -z "$seen" ]]; then echo "$name"; else echo "${seen}|${name}"; fi
}

# Profiles to try: optional GCS_WLAN_CONNECTION, then NM autoconnect, then rest.
wlan_client_profile_list() {
    load_gcs_streaming_conf
    local ap_ssid prefer seen=""
    ap_ssid="$(wlan_ap_ssid)"
    prefer="${GCS_WLAN_CONNECTION:-}"

    if [[ -n "$prefer" ]]; then
        echo "$prefer"
        seen="$(wlan_seen_add "$seen" "$prefer")"
    fi

    if [[ -f "$STA_STATE_FILE" ]]; then
        local last
        last="$(grep -E '^profile=' "$STA_STATE_FILE" | cut -d= -f2-)"
        if [[ -n "$last" && "$last" != "$prefer" && "$last" != "$ap_ssid" ]] \
            && ! wlan_seen_has "$seen" "$last"; then
            echo "$last"
            seen="$(wlan_seen_add "$seen" "$last")"
        fi
    fi

    while IFS=: read -r name type auto prio; do
        [[ "$type" != "802-11-wireless" ]] && continue
        [[ "$name" == "$ap_ssid" || "$name" == "Hotspot" || "$name" == "CaimanHS" ]] && continue
        wlan_seen_has "$seen" "$name" && continue
        if [[ "$auto" == "yes" ]]; then
            echo "$name"
            seen="$(wlan_seen_add "$seen" "$name")"
        fi
    done < <(nmcli -t -f NAME,TYPE,AUTOCONNECT,AUTOCONNECT-PRIORITY connection show 2>/dev/null \
        | sort -t: -k4 -nr)

    while IFS=: read -r name type; do
        [[ "$type" != "802-11-wireless" ]] && continue
        [[ "$name" == "$ap_ssid" || "$name" == "Hotspot" || "$name" == "CaimanHS" ]] && continue
        wlan_seen_has "$seen" "$name" && continue
        echo "$name"
        seen="$(wlan_seen_add "$seen" "$name")"
    done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null)
}

# When AP is on, prefer profiles whose SSID is visible on the locked channel.
wlan_client_profile_list_for_ap() {
    local profile ssid
    declare -A visible=()
    while IFS= read -r ssid; do
        [[ -n "$ssid" ]] && visible["$ssid"]=1
    done < <(nmcli -t -f SSID device wifi list ifname "$WLAN" 2>/dev/null)

    while IFS= read -r profile; do
        [[ -z "$profile" ]] && continue
        ssid="$(wlan_profile_ssid "$profile")"
        [[ -n "$ssid" && -n "${visible[$ssid]:-}" ]] && echo "$profile"
    done < <(wlan_client_profile_list)

    while IFS= read -r profile; do
        [[ -z "$profile" ]] && continue
        ssid="$(wlan_profile_ssid "$profile")"
        [[ -n "$ssid" && -n "${visible[$ssid]:-}" ]] && continue
        echo "$profile"
    done < <(wlan_client_profile_list)
}

wlan_try_connect_profile() {
    local profile="$1"
    local ap_active="${2:-false}"
    local channel err ap_ssid saved_profile saved_bssid saved_ch band

    ap_ssid="$(wlan_ap_ssid)"
    if [[ -n "$ap_ssid" && "$profile" == "$ap_ssid" ]]; then
        return 1
    fi

    if ! nmcli -t -f NAME connection show | grep -Fxq "$profile"; then
        return 1
    fi

    nmcli connection modify "$profile" connection.interface-name "$WLAN" 2>/dev/null || true
    wlan_unpin_nm_connection "$profile"

    if [[ "$ap_active" == true ]]; then
        channel="$(wlan_ap_channel)"
        wlan_pin_nm_connection "$profile" "$channel"
        wlan_log "  ${profile} (channel ${channel}, band $(wlan_band_for_channel "$channel"))"
    else
        wlan_log "  ${profile}"
    fi

    if err="$(nmcli -w 45 connection up "$profile" ifname "$WLAN" 2>&1)"; then
        wlan_unpin_nm_connection "$profile"
        wlan_save_sta_state "$profile"
        wlan_log "Connected: ${profile} ch=$(iw dev "$WLAN" info 2>/dev/null | awk '/channel/ {print $2; exit}')"
        return 0
    fi
    wlan_unpin_nm_connection "$profile"
    wlan_log "  failed: ${err}"
    return 1
}

wlan_connect_nm_autoconnect() {
    wlan_log "Fallback: nmcli device connect ${WLAN}"
    nmcli device wifi rescan ifname "$WLAN" 2>/dev/null || true
    sleep 2
    nmcli -w 60 device connect "$WLAN" 2>/dev/null || true
    if wlan_is_connected; then
        local profile
        profile="$(nmcli -t -f CONNECTION device show "$WLAN" 2>/dev/null | head -1)"
        [[ -n "$profile" && "$profile" != "--" ]] && wlan_save_sta_state "$profile"
        wlan_log "Connected via autoconnect: ${profile}"
        return 0
    fi
    wlan_log "Autoconnect failed"
    return 1
}

# Connect to any known NM profile (GCS_WLAN_CONNECTION preferred but optional).
# Args: optional "recover" to reset radio first (use after AP stop).
wlan_connect_client() {
    load_gcs_streaming_conf
    local profile ap_active=false recover="${1:-}"

    if wlan_is_ap_active; then
        ap_active=true
    fi

    if ! command -v nmcli >/dev/null 2>&1; then
        wlan_log "ERROR: nmcli not found"
        return 1
    fi

    if [[ "$recover" == recover || "$recover" == --recover ]]; then
        wlan_recover_radio
    fi

    wlan_prepare_nm

    if [[ "$ap_active" == false ]] && wlan_is_connected; then
        profile="$(nmcli -t -f CONNECTION device show "$WLAN" 2>/dev/null | head -1)"
        if [[ -n "$profile" && "$profile" != "--" ]]; then
            wlan_save_sta_state "$profile"
            wlan_log "Already connected: ${profile}"
            return 0
        fi
    fi

    wlan_log "Trying Wi‑Fi profiles (AP ${ap_active:+on}${ap_active:-off})..."
    if [[ "$ap_active" == true ]]; then
        profiles() { wlan_client_profile_list_for_ap; }
    else
        profiles() { wlan_client_profile_list; }
    fi
    while IFS= read -r profile; do
        [[ -z "$profile" ]] && continue
        if wlan_try_connect_profile "$profile" "$ap_active"; then
            return 0
        fi
    done < <(profiles)

    if [[ "$ap_active" == true ]]; then
        channel="$(wlan_ap_channel)"
        wlan_log "FAILED: no profile connected on channel ${channel}"
        wlan_log "  With AP on, client must use the same channel (2.4 or 5 GHz)"
        nmcli -f IN-USE,SSID,CHAN,BAND,SIGNAL device wifi list ifname "$WLAN" 2>/dev/null \
            | head -8 | sed 's/^/    /' || true
    else
        wlan_log "FAILED: no Wi‑Fi profile connected"
        wlan_connect_nm_autoconnect && return 0
    fi
    return 1
}
