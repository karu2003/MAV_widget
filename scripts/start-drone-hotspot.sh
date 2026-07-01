#!/bin/bash
# Create uap0 AP interface and start hostapd + dnsmasq (concurrent STA + AP).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/wlan-concurrent.sh
source "${SCRIPT_DIR}/wlan-concurrent.sh"

if [[ -f /var/lib/gcs-ap/manual-off ]]; then
    echo "[drone-hotspot] Manual OFF flag set — skip start (use toggle-ap to enable)"
    exit 0
fi

# Acquire exclusive radio lock — blocks keepalive from racing with AP startup.
# FD 9 is inherited by child processes and released when this script exits.
WLAN_LOCK="${WLAN_LOCK:-/run/gcs-wlan.lock}"
mkdir -p "$(dirname "$WLAN_LOCK")"
exec 9>"$WLAN_LOCK"
flock -w 60 9 || echo "[drone-hotspot] WARN: radio lock timeout — proceeding anyway"

AP="${AP:-uap0}"
AP_IP="${AP_IP:-192.168.54.1/24}"
AP_MAC="${AP_MAC:-ae:9b:01:1a:55:cc}"
AP_MODE="standalone"

log() { echo "[drone-hotspot] $*"; }

wait_for_wlan() {
    local i
    for i in $(seq 1 30); do
        if ip link show "$WLAN" &>/dev/null; then
            return 0
        fi
        sleep 1
    done
    log "ERROR: $WLAN not found after 30s"
    return 1
}

stop_services() {
    if systemctl is-active --quiet dnsmasq; then
        log "Stopping dnsmasq"
        systemctl stop dnsmasq
    fi
    if systemctl is-active --quiet hostapd; then
        log "Stopping hostapd"
        systemctl stop hostapd
    fi
}

setup_interface() {
    log "Waiting for $WLAN..."
    wait_for_wlan

    stop_services

    mkdir -p "$GCS_AP_STATE"
    if wlan_sta_is_linked; then
        AP_MODE="concurrent"
        # Save BSSID + profile + channel NOW, before hostapd sends DEAUTH.
        # wlan_connect_client uses this to reconnect without any scanning.
        local _cur_profile
        _cur_profile="$(nmcli -t -f GENERAL.CONNECTION device show "$WLAN" 2>/dev/null \
            | head -1 | cut -d: -f2-)"
        [[ -z "$_cur_profile" || "$_cur_profile" == "--" ]] && _cur_profile="${GCS_WLAN_CONNECTION:-}"
        wlan_save_sta_state "${_cur_profile:-}"
        log "wlan0 connected — concurrent mode (saved profile=${_cur_profile:-?})"
    else
        AP_MODE="standalone"
        log "wlan0 is not connected — AP starts in standalone mode"
    fi
    echo "$AP_MODE" >"$AP_MODE_FILE"

    # One radio / one channel:
    # - if wlan0 is already connected, AP follows wlan0's channel
    # - if wlan0 is not connected, AP picks a free standalone channel
    # Never pin channel/band/BSSID into saved NetworkManager client profiles.
    wlan_sync_ap_channel_to_sta

    ip link set "$WLAN" up || true

    if ip link show "$AP" &>/dev/null; then
        log "Removing existing $AP"
        iw dev "$AP" del || true
        sleep 1
    fi

    log "Creating $AP on $WLAN"
    iw dev "$WLAN" interface add "$AP" type __ap
    ip link set dev "$AP" address "$AP_MAC"
    # Keep NetworkManager from managing/flushing the AP IP (MT7921 etc.).
    nmcli device set "$AP" managed no 2>/dev/null || true
    ip link set "$AP" down
    ip link set "$AP" up

    if ! ip addr show dev "$AP" | grep -q "${AP_IP%/*}"; then
        log "Assigning $AP_IP to $AP"
        ip addr add "$AP_IP" dev "$AP" 2>/dev/null || true
    fi
}

start_services() {
    log "Starting hostapd"
    if ! systemctl start hostapd; then
        log "ERROR: hostapd failed — check: journalctl -u hostapd -n 20"
        log "  Common fix: sudo ensure-hostapd-concurrent.sh && remove noscan from hostapd conf"
        return 1
    fi
    if [[ "$AP_MODE" == "concurrent" ]]; then
        # MT7921: driver sends DEAUTH to wlan0 STA when AP starts (nl80211_start_ap).
        # Stop NM retries IMMEDIATELY — each AUTH_REJECT resets the router hold-down.
        nmcli device disconnect "$WLAN" 2>/dev/null || true
    fi
    sleep 2

    if ! systemctl is-active --quiet hostapd; then
        log "ERROR: hostapd not active"
        return 1
    fi

    log "Starting dnsmasq"
    systemctl start dnsmasq

    if [[ -x /usr/local/bin/setup-nat.sh ]]; then
        log "Applying NAT / forwarding"
        /usr/local/bin/setup-nat.sh || log "WARN: setup-nat failed"
    elif [[ -x "${SCRIPT_DIR}/setup-nat.sh" ]]; then
        log "Applying NAT / forwarding"
        "${SCRIPT_DIR}/setup-nat.sh" || log "WARN: setup-nat failed"
    fi

    # MT7921: AP start locks wlan0 TX power to ~3 dBm (concurrent mode bug).
    # Restore regulatory domain + auto power so wlan0 can maintain a stable link.
    log "Restoring wlan0 TX power after AP start"
    wlan_fix_radio_power
}

restore_wlan_client() {
    if [[ -x /usr/local/bin/restore-wlan-client.sh ]]; then
        timeout 50 /usr/local/bin/restore-wlan-client.sh
    else
        timeout 50 "${SCRIPT_DIR}/restore-wlan-client.sh"
    fi
}

setup_interface
if ! start_services; then
    log "WARN: AP services failed — wlan0 client may still work"
    exit 1
fi

if [[ "$AP_MODE" == "concurrent" ]]; then
    if ! restore_wlan_client; then
        log "WARN: wlan0 client restore failed — keepalive will retry every 20s"
    fi
else
    log "Standalone AP mode — not touching wlan0 while AP is up"
fi

if [[ "$AP_MODE" == "concurrent" ]]; then
    systemctl enable --now gcs-wlan-keepalive.timer 2>/dev/null \
        || log "WARN: enable gcs-wlan-keepalive.timer manually"
else
    systemctl disable --now gcs-wlan-keepalive.timer 2>/dev/null || true
fi

if [[ -x /usr/local/bin/restart-ap-streaming.sh ]]; then
    /usr/local/bin/restart-ap-streaming.sh || log "WARN: AP streaming restart failed"
elif [[ -x "${SCRIPT_DIR}/restart-ap-streaming.sh" ]]; then
    "${SCRIPT_DIR}/restart-ap-streaming.sh" || log "WARN: AP streaming restart failed"
fi

SSID="$(grep -E '^ssid=' "$HOSTAPD_CONF" 2>/dev/null | cut -d= -f2- || echo 'AP')"
log "AP ready: SSID ${SSID} on $AP ($AP_IP), mode=${AP_MODE}, wlan0 $(nmcli -t -f GENERAL.STATE device show "$WLAN" 2>/dev/null | cut -d: -f2- || echo unknown)"
