#!/bin/bash
# Helpers: concurrent wlan0 (STA) + uap0 (AP) on one radio (#channels <= 1).

set -euo pipefail

WLAN="${WLAN:-wlan0}"
AP="${AP:-uap0}"
HOSTAPD_CONF="${HOSTAPD_CONF:-/etc/hostapd/drone-hotspot.conf}"
GCS_AP_STATE="${GCS_AP_STATE:-/var/lib/gcs-ap}"
STA_STATE_FILE="${GCS_AP_STATE}/wlan-sta.state"
AP_MODE_FILE="${GCS_AP_STATE}/ap-mode"
DEFAULT_AP_CHANNEL="${DEFAULT_AP_CHANNEL:-6}"
DEFAULT_AP_HW_MODE="${DEFAULT_AP_HW_MODE:-g}"
WLAN_STA_WAIT_SEC="${WLAN_STA_WAIT_SEC:-30}"
WLAN_REG_DOMAIN="${WLAN_REG_DOMAIN:-DE}"

load_gcs_streaming_conf() {
    local conf="${GCS_STREAMING_CONF:-/etc/default/gcs-ap-streaming}"
    if [[ -f "$conf" ]]; then
        # shellcheck disable=SC1090
        source "$conf"
    fi
}

wlan_log() { echo "[wlan-concurrent] $*" >&2; }

# MT7921 often stuck at ~3 dBm after AP mode; auth frames then time out (NM: ssid-not-found).
wlan_fix_radio_power() {
    if [[ -n "${WLAN_REG_DOMAIN:-}" ]]; then
        iw reg set "$WLAN_REG_DOMAIN" 2>/dev/null || true
    fi
    iw dev "$WLAN" set txpower auto 2>/dev/null || \
        iw dev "$WLAN" set txpower fixed 2000 2>/dev/null || true
}

wlan_wait_for_ssid() {
    local ssid="$1" i bssid
    for i in $(seq 1 12); do
        nmcli device wifi rescan ifname "$WLAN" 2>/dev/null || true
        sleep 2
        bssid="$(wlan_bssid_for_ssid "$ssid")"
        [[ -n "$bssid" ]] && return 0
    done
    return 1
}

wlan_ap_ssid() {
    grep -E '^ssid=' "$HOSTAPD_CONF" 2>/dev/null | cut -d= -f2- || true
}

wlan_is_ap_active() {
    ip link show "$AP" &>/dev/null && systemctl is-active --quiet hostapd 2>/dev/null
}

wlan_ap_mode() {
    if [[ -f "$AP_MODE_FILE" ]]; then
        head -1 "$AP_MODE_FILE"
    else
        echo unknown
    fi
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

# Pick a low-congestion AP channel when there is no active wlan0 client.
# Keep this to 2.4 GHz non-overlapping channels for phone compatibility and to
# avoid DFS/CAC delays on 5 GHz AP startup.
wlan_choose_free_ap_channel() {
    local ch best_ch="${DEFAULT_AP_CHANNEL}" best_score=999 score
    declare -A counts=([1]=0 [6]=0 [11]=0)

    nmcli device wifi rescan ifname "$WLAN" 2>/dev/null || true
    sleep 2

    while IFS= read -r ch; do
        [[ "$ch" =~ ^[0-9]+$ ]] || continue
        case "$ch" in
            1|2|3) counts[1]=$((counts[1] + 1)) ;;
            4|5|6|7|8) counts[6]=$((counts[6] + 1)) ;;
            9|10|11|12|13) counts[11]=$((counts[11] + 1)) ;;
        esac
    done < <(nmcli -t -f CHAN device wifi list ifname "$WLAN" 2>/dev/null)

    for ch in 1 6 11; do
        score="${counts[$ch]:-0}"
        if (( score < best_score )); then
            best_score="$score"
            best_ch="$ch"
        fi
    done

    echo "$best_ch"
}

# Set hostapd channel/hw_mode:
# - if wlan0 is connected, AP must use the current wlan0 channel
# - if wlan0 is not connected, AP chooses a free standalone channel
# This must never write channel/band/BSSID pins into NetworkManager profiles.
wlan_sync_ap_channel_to_sta() {
    local ch hw freq

    if wlan_sta_is_linked; then
        freq="$(iw dev "$WLAN" link 2>/dev/null | awk '/freq:/ {print $2; exit}')"
        ch="$(iw dev "$WLAN" info 2>/dev/null | awk '/channel/ {print $2; exit}')"
        hw="$(wlan_hw_mode_from_freq "$freq")"
        [[ -z "$ch" ]] && ch="${DEFAULT_AP_CHANNEL}"
        wlan_log "wlan0 connected — AP follows Wi-Fi channel=${ch}, hw_mode=${hw}"
        wlan_apply_hostapd_rf "$ch" "$hw"
        return 0
    fi

    ch="$(wlan_choose_free_ap_channel)"
    hw="$(wlan_hw_mode_for_channel "$ch")"
    wlan_log "wlan0 not connected — AP standalone channel=${ch}, hw_mode=${hw}"
    wlan_apply_hostapd_rf "$ch" "$hw"
}

wlan_link_bssid() {
    iw dev "$WLAN" link 2>/dev/null | awk '/Connected to/ {print $3; exit}'
}

wlan_is_connected() {
    # Use 'device status' — 'device show' with -f STATE returns empty in NM 1.36.
    nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep -q "^${WLAN}:connected"
}

# True if wlan0 NM state is anything other than disconnected/unavailable/unmanaged.
# Use in keepalive to avoid interrupting an in-progress connection attempt.
wlan_sta_is_busy() {
    local state
    state=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep "^${WLAN}:" | cut -d: -f2)
    [[ -n "$state" && "$state" != "disconnected" && "$state" != "unavailable" && "$state" != "unmanaged" ]]
}

# Disable wpa_supplicant background scanning for the current network.
# On a single-radio concurrent STA+AP, bgscan goes off-channel and disrupts
# both the STA association and AP clients.
wlan_disable_bgscan() {
    local netid
    netid=$(wpa_cli -i "$WLAN" list_networks 2>/dev/null | awk 'NR>1 {print $1; exit}')
    [[ -z "$netid" ]] && return 0
    wpa_cli -i "$WLAN" set_network "$netid" bgscan '""' 2>/dev/null || true
    wlan_log "Disabled bgscan (network ${netid}) on ${WLAN}"
}

wlan_save_sta_state() {
    local profile="${1:-${GCS_WLAN_CONNECTION:-}}"
    local ch bssid ssid freq band hw
    mkdir -p "$GCS_AP_STATE"
    ch="$(iw dev "$WLAN" info 2>/dev/null | awk '/channel/ {print $2; exit}')"
    bssid="$(wlan_link_bssid)"
    ssid="$(iw dev "$WLAN" link 2>/dev/null | awk -F': ' '/SSID:/ {print $2; exit}')"
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
    # beacon_int=100 is needed for concurrent STA+AP to keep beacons regular.
    # noscan is NOT supported in hostapd v2.x and must not be added.
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

# Reset Wi‑Fi after AP mode without editing saved NetworkManager profiles.
wlan_recover_radio() {
    wlan_log "Resetting ${WLAN} radio after AP"
    local i state

    # 1. Stop AP services if still running (idempotent — caller may have done this).
    systemctl is-active --quiet hostapd 2>/dev/null \
        && systemctl stop hostapd 2>/dev/null || true
    systemctl is-active --quiet dnsmasq 2>/dev/null \
        && systemctl stop dnsmasq  2>/dev/null || true

    # 2. Remove virtual AP interface — poll until confirmed gone.
    if ip link show "$AP" &>/dev/null; then
        ip link set "$AP" down 2>/dev/null || true
        iw dev "$AP" del 2>/dev/null || true
        for i in $(seq 1 5); do
            ip link show "$AP" &>/dev/null || break
            sleep 1
        done
    fi

    # 3. Take wlan0 out of NM control for the radio reset.
    nmcli device set "$WLAN" managed no 2>/dev/null || true
    ip link set "$WLAN" down 2>/dev/null || true

    # 4. Poll until interface is DOWN — iw type change requires the interface to be down.
    for i in $(seq 1 5); do
        state="$(ip -br link show "$WLAN" 2>/dev/null | awk '{print $2}')"
        [[ "$state" != "UP" ]] && break
        sleep 1
    done

    # 5. Reset radio type to managed — MUST be done while the interface is DOWN.
    iw dev "$WLAN" set type managed 2>/dev/null || true

    # 6. Unblock radio.
    rfkill unblock wifi 2>/dev/null || true

    # 7. Return interface to NM — NM will bring wlan0 UP.
    nmcli radio wifi on 2>/dev/null || true
    nmcli device set "$WLAN" managed yes 2>/dev/null || true

    # 8. Poll until UP; nudge with ip link set if NM is slow (≥3 s).
    for i in $(seq 1 10); do
        state="$(ip -br link show "$WLAN" 2>/dev/null | awk '{print $2}')"
        [[ "$state" == "UP" ]] && break
        [[ "$i" -eq 3 ]] && { ip link set "$WLAN" up 2>/dev/null || true; }
        sleep 1
    done

    # 9. Fix TX power (MT7921: stuck at ~3 dBm after AP mode; requires interface UP).
    wlan_fix_radio_power

    # 10. Trigger background scan — results ready by the time the connect loop starts.
    nmcli device wifi rescan ifname "$WLAN" 2>/dev/null || true
    sleep 2

    state="$(ip -br link show "$WLAN" 2>/dev/null | awk '{print $2}')"
    local tp
    tp="$(iw dev "$WLAN" info 2>/dev/null | awk '/txpower/ {print $2; exit}')"
    wlan_log "  ${WLAN} state=${state} txpower=${tp:-?}dBm"
}

wlan_prepare_nm() {
    nmcli radio wifi on 2>/dev/null || true
    nmcli device set "$WLAN" managed yes 2>/dev/null || true
    if ip link show "$AP" &>/dev/null; then
        nmcli device set "$AP" managed no 2>/dev/null || true
        # While AP is running, only nudge TX power (no iw reg set — that can
        # change channel constraints and disrupt uap0 clients).
        iw dev "$WLAN" set txpower auto 2>/dev/null || true
    else
        wlan_fix_radio_power
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

# Channel visible on wlan0 scan for SSID (no active connection needed).
wlan_chan_for_ssid() {
    local ssid="$1" line ch rest
    while IFS= read -r line; do
        ch="${line%%:*}"
        [[ "$ch" =~ ^[0-9]+$ ]] || continue
        rest="${line#*:}"
        rest="${rest//\\:/:}"  # unescape \: \u2192 : in SSID field
        [[ "$rest" == "$ssid" ]] || continue
        echo "$ch"
        return 0
    done < <(nmcli -t -f CHAN,SSID device wifi list ifname "$WLAN" 2>/dev/null)
}
# BSSID visible on wlan0 scan for SSID on a specific channel.
# In concurrent STA+AP mode both interfaces share one channel, so we must
# connect wlan0 to a router BSSID that is on the AP's channel (not 5 GHz).
wlan_bssid_for_ssid_on_channel() {
    local ssid="$1" want_ch="$2"
    local line bssid ch_part rest
    while IFS= read -r line; do
        # nmcli -t -f BSSID,CHAN,SSID: BSSID always 22 chars (AA\:BB\:CC\:DD\:EE\:FF)
        [[ ${#line} -gt 22 && "${line:22:1}" == ":" ]] || continue
        bssid="${line:0:22}"
        bssid="${bssid//\\:/:}"      # unescape \: \u2192 :
        rest="${line:23}"            # CHAN:SSID
        ch_part="${rest%%:*}"        # channel number
        rest="${rest#*:}"            # SSID
        rest="${rest//\\:/:}"       # unescape SSID
        [[ "$ch_part" == "$want_ch" && "$rest" == "$ssid" ]] || continue
        echo "$bssid"
        return 0
    done < <(nmcli -t -f BSSID,CHAN,SSID device wifi list ifname "$WLAN" 2>/dev/null)
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
        [[ "$name" =~ [[:space:]][0-9]+$ ]] && continue
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
        [[ "$name" =~ [[:space:]][0-9]+$ ]] && continue
        wlan_seen_has "$seen" "$name" && continue
        echo "$name"
        seen="$(wlan_seen_add "$seen" "$name")"
    done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null)
}

# When AP is on, use the profile saved before AP started — no scan needed
# because the AP runs on the same channel the STA was already connected to.
wlan_client_profile_list_for_ap() {
    local saved_profile ap_ssid
    ap_ssid="$(wlan_ap_ssid)"

    if [[ -f "$STA_STATE_FILE" ]]; then
        saved_profile="$(grep -E '^profile=' "$STA_STATE_FILE" 2>/dev/null | cut -d= -f2-)"
        if [[ -n "$saved_profile" && "$saved_profile" != "$ap_ssid" ]] \
            && nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq "$saved_profile"; then
            echo "$saved_profile"
            return
        fi
    fi

    # State file missing or stale — fall back to full list so keepalive can recover.
    wlan_client_profile_list
}

wlan_try_connect_profile() {
    local profile="$1"
    local ap_active="${2:-false}"
    local already_scanned="${3:-false}"
    local channel err ap_ssid connect_timeout=30

    ap_ssid="$(wlan_ap_ssid)"
    if [[ -n "$ap_ssid" && "$profile" == "$ap_ssid" ]]; then
        return 1
    fi

    if ! nmcli -t -f NAME connection show | grep -Fxq "$profile"; then
        return 1
    fi

    local up_extra=()
    if [[ "$ap_active" == true ]]; then
        channel="$(wlan_ap_channel)"
        local pssid bssid
        connect_timeout=20
        pssid="$(wlan_profile_ssid "$profile")"

        # Priority 1: saved BSSID from before AP started — no scan at all.
        bssid=""
        if [[ -f "$STA_STATE_FILE" ]]; then
            local _sv_profile _sv_bssid
            _sv_profile="$(grep -E '^profile=' "$STA_STATE_FILE" 2>/dev/null | cut -d= -f2-)"
            _sv_bssid="$(grep -E '^bssid=' "$STA_STATE_FILE" 2>/dev/null | cut -d= -f2-)"
            if [[ "$_sv_profile" == "$profile" && -n "$_sv_bssid" ]]; then
                bssid="$_sv_bssid"
                wlan_log "  ${profile}: using saved BSSID ${bssid} (no scan)"
            fi
        fi

        # Priority 2: scan cache only (no active rescan — off-channel scan disrupts AP).
        if [[ -z "$bssid" ]]; then
            bssid="$(wlan_bssid_for_ssid_on_channel "$pssid" "$channel")"
            [[ -n "$bssid" ]] && wlan_log "  ${profile}: BSSID ${bssid} from cache (ch ${channel})"
        fi

        if [[ -n "$bssid" ]]; then
            up_extra=(ap "$bssid")
        else
            wlan_log "  ${profile} skipped — BSSID unknown, no scan while AP is up"
            return 1
        fi
    else
        if [[ "$already_scanned" != true ]]; then
            nmcli device wifi rescan ifname "$WLAN" 2>/dev/null || true
            sleep 2
        fi
        local pssid bssid
        pssid="$(wlan_profile_ssid "$profile")"
        bssid="$(wlan_bssid_for_ssid "$pssid")"
        if [[ -n "$bssid" ]]; then
            up_extra=(ap "$bssid")
            wlan_log "  ${profile} (BSSID ${bssid})"
        else
            # SSID not in current scan — short timeout to avoid a 45 s stall per profile.
            connect_timeout=15
            wlan_log "  ${profile} (SSID not visible, timeout=${connect_timeout}s)"
        fi
    fi

    if err="$(nmcli -w "${connect_timeout}" connection up "$profile" ifname "$WLAN" "${up_extra[@]}" 2>&1)"; then
        wlan_save_sta_state "$profile"
        wlan_log "Connected: ${profile} ch=$(iw dev "$WLAN" info 2>/dev/null | awk '/channel/ {print $2; exit}')"
        # Disable bgscan to prevent off-channel scans from disrupting concurrent STA+AP.
        [[ "$ap_active" == true ]] && wlan_disable_bgscan
        return 0
    fi
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
        profile="$(nmcli -t -f GENERAL.CONNECTION device show "$WLAN" 2>/dev/null | cut -d: -f2-)"
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

    if [[ -x /usr/local/bin/cleanup-nm-wifi-duplicates.sh ]]; then
        /usr/local/bin/cleanup-nm-wifi-duplicates.sh >&2 || true
    elif [[ -x "$(dirname "${BASH_SOURCE[0]}")/cleanup-nm-wifi-duplicates.sh" ]]; then
        "$(dirname "${BASH_SOURCE[0]}")/cleanup-nm-wifi-duplicates.sh" >&2 || true
    fi

    if [[ "$recover" == recover || "$recover" == --recover ]]; then
        wlan_recover_radio
        # wlan_recover_radio() already handles: managed yes, link up, fix_power, rescan.
        # Calling wlan_prepare_nm() would duplicate all of that — skip it after recover.
    else
        wlan_prepare_nm
    fi

    if wlan_is_connected; then
        profile="$(nmcli -t -f GENERAL.CONNECTION device show "$WLAN" 2>/dev/null | cut -d: -f2-)"
        if [[ -n "$profile" && "$profile" != "--" ]]; then
            wlan_save_sta_state "$profile"
            wlan_log "Already connected: ${profile} (AP ${ap_active:+on}${ap_active:-off})"
            return 0
        fi
    fi

    wlan_log "Trying Wi‑Fi profiles (AP ${ap_active:+on}${ap_active:-off})..."
    if [[ "$ap_active" == true ]]; then
        profiles() { wlan_client_profile_list_for_ap; }
    else
        profiles() { wlan_client_profile_list; }
    fi
    # When AP is off: one upfront scan, then no per-profile rescans.
    # When AP is on: no scan at all — saved BSSID is used directly.
    local _scanned=false
    if [[ "$ap_active" == true ]]; then
        _scanned=true   # no scan in concurrent mode — use saved BSSID
    elif [[ "$recover" == recover || "$recover" == --recover ]]; then
        _scanned=true   # wlan_recover_radio() already scanned
    else
        nmcli device wifi rescan ifname "$WLAN" 2>/dev/null || true
        sleep 2
        _scanned=true
    fi
    while IFS= read -r profile; do
        [[ -z "$profile" ]] && continue
        if wlan_try_connect_profile "$profile" "$ap_active" "$_scanned"; then
            return 0
        fi
    done < <(profiles)

    if [[ "$ap_active" == true ]]; then
        channel="$(wlan_ap_channel)"
        wlan_log "FAILED: no client on channel ${channel} while AP is up"
        wlan_log "  Both run at once on one channel — need a saved profile for a network on ch ${channel}"
        nmcli -f IN-USE,SSID,CHAN,BAND,SIGNAL device wifi list ifname "$WLAN" 2>/dev/null \
            | head -8 | sed 's/^/    /' || true
    else
        wlan_log "FAILED: no Wi‑Fi profile connected"
        wlan_connect_nm_autoconnect && return 0
    fi
    return 1
}
