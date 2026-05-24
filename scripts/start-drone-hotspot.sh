#!/bin/bash
# Create uap0 AP interface and start hostapd + dnsmasq.

set -euo pipefail

WLAN="${WLAN:-wlan0}"
AP="${AP:-uap0}"
AP_IP="${AP_IP:-192.168.54.1/24}"
AP_MAC="${AP_MAC:-ae:9b:01:1a:55:cc}"
HOSTAPD_CONF="${HOSTAPD_CONF:-/etc/hostapd/drone-hotspot.conf}"

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

sync_channel() {
    local channel
    channel="$(iw dev "$WLAN" info 2>/dev/null | awk '/channel/ {print $2; exit}')"
    if [[ -n "$channel" ]]; then
        log "Sync AP channel to wlan0 channel $channel"
        sed -i "s/^channel=.*/channel=$channel/" "$HOSTAPD_CONF"
    else
        log "wlan0 has no channel, using default channel 6"
        sed -i "s/^channel=.*/channel=6/" "$HOSTAPD_CONF"
    fi
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
    sync_channel

    log "Starting hostapd"
    systemctl start hostapd
    sleep 1

    log "Starting dnsmasq"
    systemctl start dnsmasq

    if [[ -x /usr/local/bin/setup-nat.sh ]]; then
        log "Applying NAT / forwarding"
        /usr/local/bin/setup-nat.sh || log "WARN: setup-nat failed"
    elif [[ -x "$(dirname "$0")/setup-nat.sh" ]]; then
        log "Applying NAT / forwarding"
        "$(dirname "$0")/setup-nat.sh" || log "WARN: setup-nat failed"
    fi
}

setup_interface
start_services

if [[ -x /usr/local/bin/restart-ap-streaming.sh ]]; then
    /usr/local/bin/restart-ap-streaming.sh || log "WARN: AP streaming restart failed"
elif [[ -x "$(dirname "$0")/restart-ap-streaming.sh" ]]; then
    "$(dirname "$0")/restart-ap-streaming.sh" || log "WARN: AP streaming restart failed"
fi

SSID="$(grep -E '^ssid=' "$HOSTAPD_CONF" 2>/dev/null | cut -d= -f2- || echo 'AP')"
log "AP ready: SSID ${SSID} on $AP ($AP_IP)"
