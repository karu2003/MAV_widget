#!/bin/bash
# Helpers: concurrent wlan0 (STA) + uap0 (AP) on one radio (#channels <= 1).

set -euo pipefail

WLAN="${WLAN:-wlan0}"
AP="${AP:-uap0}"
HOSTAPD_CONF="${HOSTAPD_CONF:-/etc/hostapd/drone-hotspot.conf}"
GCS_AP_STATE="${GCS_AP_STATE:-/var/lib/gcs-ap}"
STA_STATE_FILE="${GCS_AP_STATE}/wlan-sta.state"
DEFAULT_AP_CHANNEL="${DEFAULT_AP_CHANNEL:-6}"
DEFAULT_AP_HW_MODE="${DEFAULT_AP_HW_MODE:-g}"
WLAN_STA_WAIT_SEC="${WLAN_STA_WAIT_SEC:-30}"

load_gcs_streaming_conf() {
    local conf="${GCS_STREAMING_CONF:-/etc/default/gcs-ap-streaming}"
    if [[ -f "$conf" ]]; then
        # shellcheck disable=SC1090
        source "$conf"
    fi
}

wlan_log() { echo "[wlan-concurrent] $*" >&2; }

wlan_ap_ssid() {
    grep -E '^ssid=' "$HOSTAPD_CONF" 2>/dev/null | cut -d= -f2- || true
}

wlan_is_ap_active() {
    ip link show "$AP" &>/dev/null && systemctl is-active --quiet hostapd 2>/dev/null
}

# Channel for concurrent STA+AP (prefer live AP/uap0 when AP is running).
wlan_ap_channel() {
    local ch
    ch="$(iw dev "$WLAN" info 2>/dev/null | awk '/channel/ {print $2; exit}')"
    if [[ -n "$ch" ]]; then
        echo "$ch"
        return 0
    fi
    if wlan_is_ap_active; then
        ch="$(iw dev "$AP" info 2>/dev/null | awk '/channel/ {print $2; exit}')"
        if [[ -n "$ch" ]]; then
            echo "$ch"
            return 0
        fi
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

# hw_mode from link frequency (MHz): >=5000 → 5 GHz (a), else 2.4 GHz (g).
wlan_hw_mode_from_freq() {
    local freq="$1"
    freq="${freq//MHz/}"
    freq="${freq// /}"
    if [[ -n "$freq" && "$freq" -ge 5000 ]]; then
        echo "a"
    else
        echo "g"
    fi
}

wlan_sta_is_linked() {
    iw dev "$WLAN" link 2>/dev/null | grep -q "Connected to"
}

# Read channel + hw_mode from active wlan0 STA link (concurrent: AP must match).
wlan_read_sta_rf() {
    local freq ch hw
    if ! wlan_sta_is_linked; then
        echo "${DEFAULT_AP_CHANNEL} ${DEFAULT_AP_HW_MODE} 0"
        return 1
    fi
    freq="$(iw dev "$WLAN" link 2>/dev/null | awk '/freq:/ {print $2; exit}')"
    ch="$(iw dev "$WLAN" info 2>/dev/null | awk '/channel/ {print $2; exit}')"
    hw="$(wlan_hw_mode_from_freq "$freq")"
    [[ -z "$ch" ]] && ch="${DEFAULT_AP_CHANNEL}"
    echo "${ch} ${hw} ${freq}"
    return 0
}

# Wait for wlan0 client, then set hostapd channel/hw_mode to match (or defaults).
wlan_sync_ap_channel_to_sta() {
    local i ch hw freq connected=0

    wlan_log "Waiting for ${WLAN} client — AP will use the same channel"
    for i in $(seq 1 "$WLAN_STA_WAIT_SEC"); do
        if wlan_sta_is_linked; then
            connected=1
            break
        fi
        sleep 1
    done

    if [[ "$connected" -eq 1 ]]; then
        freq="$(iw dev "$WLAN" link 2>/dev/null | awk '/freq:/ {print $2; exit}')"
        ch="$(iw dev "$WLAN" info 2>/dev/null | awk '/channel/ {print $2; exit}')"
        hw="$(wlan_hw_mode_from_freq "$freq")"
        [[ -z "$ch" ]] && ch="${DEFAULT_AP_CHANNEL}"
        wlan_log "Client active — freq=${freq} MHz, channel=${ch}, hw_mode=${hw}"
    else
        ch="${DEFAULT_AP_CHANNEL}"
        hw="${DEFAULT_AP_HW_MODE}"
        wlan_log "Client not connected — AP defaults: channel=${ch}, hw_mode=${hw}"
    fi

    wlan_apply_hostapd_rf "$ch" "$hw"
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
    freq="$(iw dev "$WLAN" link 2>/dev/null | awk '/freq:/ {print $2; exit}')"
    band="$(wlan_band_for_channel "${ch:-6}")"
    hw="$(wlan_hw_mode_from_freq "$freq")"
    [[ -z "$ch" ]] && hw="$(wlan_hw_mode_for_channel "${DEFAULT_AP_CHANNEL}")"
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
    local hw_mode="${2:-$(wlan_hw_mode_for_channel "$channel")}"
    local band
    band="$(wlan_band_for_channel "$channel")"
    [[ -f "$HOSTAPD_CONF" ]] || return 0
    wlan_ensure_hostapd_concurrent_opts
    if grep -q '^hw_mode=' "$HOSTAPD_CONF"; then
        sed -i "s/^hw_mode=.*/hw_mode=${hw_mode}/" "$HOSTAPD_CONF"
    else
        echo "hw_mode=${hw_mode}" >>"$HOSTAPD_CONF"
    fi
    sed -i "s/^channel=.*/channel=${channel}/" "$HOSTAPD_CONF"
    wlan_log "hostapd synced: hw_mode=${hw_mode} channel=${channel} (${band}, same as ${WLAN} client)"
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

# BSSID visible on wlan0 scan for SSID (works while AP locks channel).
wlan_bssid_for_ssid() {
    local ssid="$1"
    local line bssid
    while IFS= read -r line; do
        [[ "$line" == *":${ssid}" ]] || continue
        bssid="${line%:${ssid}}"
        bssid="${bssid//\\:/:}"
        echo "$bssid"
        return 0
    done < <(nmcli -t -f BSSID,SSID device wifi list ifname "$WLAN" 2>/dev/null)
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
        local pssid bssid
        pssid="$(wlan_profile_ssid "$profile")"
        wlan_pin_nm_connection "$profile" "$channel"
        bssid="$(wlan_bssid_for_ssid "$pssid")"
        if [[ -n "$bssid" ]]; then
            nmcli connection modify "$profile" 802-11-wireless.bssid "$bssid" 2>/dev/null || true
            wlan_log "  ${profile} (AP ch ${channel}, BSSID ${bssid})"
        else
            wlan_log "  ${profile} (AP ch ${channel})"
        fi
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

    if wlan_is_connected; then
        profile="$(nmcli -t -f CONNECTION device show "$WLAN" 2>/dev/null | head -1)"
        if [[ -n "$profile" && "$profile" != "--" ]]; then
            wlan_save_sta_state "$profile"
            wlan_log "Already connected: ${profile} (AP ${ap_active:+on}${ap_active:-off})"
            return 0
        fi
    fi

    if [[ "$ap_active" == true ]]; then
        nmcli device wifi rescan ifname "$WLAN" 2>/dev/null || true
        sleep 2
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
        wlan_log "FAILED: no client on channel ${channel} while AP is up"
        wlan_log "  Both run at once on one channel — need a saved profile for a network on ch ${channel}"
        nmcli -f IN-USE,SSID,CHAN,BAND,SIGNAL device wifi list ifname "$WLAN" 2>/dev/null \
            | head -8 | sed 's/^/    /' || true
        wlan_connect_nm_autoconnect && return 0
    else
        wlan_log "FAILED: no Wi‑Fi profile connected"
        wlan_connect_nm_autoconnect && return 0
    fi
    return 1
}
