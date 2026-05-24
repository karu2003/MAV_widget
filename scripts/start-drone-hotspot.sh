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

AP="${AP:-uap0}"
AP_IP="${AP_IP:-192.168.54.1/24}"
AP_MAC="${AP_MAC:-ae:9b:01:1a:55:cc}"

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

preconnect_wlan() {
    if ! command -v nmcli >/dev/null 2>&1; then
        return 0
    fi
    log "Connect ${WLAN} before AP (AP channel = client channel)"
    wlan_connect_client || log "WARN: pre-connect failed — will wait for link or use default ch ${DEFAULT_AP_CHANNEL}"
}

setup_interface() {
    log "Waiting for $WLAN..."
    wait_for_wlan

    stop_services

    preconnect_wlan

    # One radio / one channel: AP hw_mode+channel must match router (STA link).
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
    ip link set "$AP" down
    iw dev "$AP" set type __ap
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
}

restore_wlan_client() {
    if [[ -x /usr/local/bin/restore-wlan-client.sh ]]; then
        timeout 120 /usr/local/bin/restore-wlan-client.sh
    else
        timeout 120 "${SCRIPT_DIR}/restore-wlan-client.sh"
    fi
}

setup_interface
if ! start_services; then
    log "WARN: AP services failed — wlan0 client may still work"
    exit 1
fi

if ! restore_wlan_client; then
    log "WARN: wlan0 client restore failed — keepalive will retry every 20s"
fi

systemctl enable --now gcs-wlan-keepalive.timer 2>/dev/null \
    || log "WARN: enable gcs-wlan-keepalive.timer manually"

if [[ -x /usr/local/bin/restart-ap-streaming.sh ]]; then
    /usr/local/bin/restart-ap-streaming.sh || log "WARN: AP streaming restart failed"
elif [[ -x "${SCRIPT_DIR}/restart-ap-streaming.sh" ]]; then
    "${SCRIPT_DIR}/restart-ap-streaming.sh" || log "WARN: AP streaming restart failed"
fi

SSID="$(grep -E '^ssid=' "$HOSTAPD_CONF" 2>/dev/null | cut -d= -f2- || echo 'AP')"
log "AP ready: SSID ${SSID} on $AP ($AP_IP), wlan0 $(nmcli -t -f STATE device show "$WLAN" 2>/dev/null | head -1 || echo unknown)"
