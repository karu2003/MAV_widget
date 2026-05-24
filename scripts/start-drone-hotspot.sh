#!/bin/bash
# Create uap0 AP interface and start hostapd + dnsmasq.

set -euo pipefail

if [[ -f /var/lib/gcs-ap/manual-off ]]; then
    echo "[drone-hotspot] Manual OFF flag set — skip start (use toggle-ap to enable)"
    exit 0
fi

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

load_streaming_conf() {
    CONF="${GCS_STREAMING_CONF:-/etc/default/gcs-ap-streaming}"
    if [[ -f "$CONF" ]]; then
        # shellcheck disable=SC1090
        source "$CONF"
    fi
}

preconnect_wlan() {
    load_streaming_conf
    [[ -n "${GCS_WLAN_CONNECTION:-}" ]] || return 0
    if ! command -v nmcli >/dev/null 2>&1; then
        return 0
    fi
    log "Pre-connect $WLAN (${GCS_WLAN_CONNECTION}) for AP channel sync"
    nmcli radio wifi on 2>/dev/null || true
    nmcli device set "$WLAN" managed yes 2>/dev/null || true
    ip link set "$WLAN" up 2>/dev/null || true
    if nmcli -w 30 connection up "${GCS_WLAN_CONNECTION}" ifname "$WLAN" 2>/dev/null; then
        ch="$(iw dev "$WLAN" info 2>/dev/null | awk '/channel/ {print $2; exit}')"
        log "wlan0 connected on channel ${ch:-?}"
    else
        log "WARN: pre-connect ${GCS_WLAN_CONNECTION} failed (AP will use default channel 6)"
    fi
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

    preconnect_wlan

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

restore_wlan_client() {
    if [[ -x /usr/local/bin/restore-wlan-client.sh ]]; then
        timeout 45 /usr/local/bin/restore-wlan-client.sh || log "WARN: wlan0 client restore failed"
    elif [[ -x "$(dirname "$0")/restore-wlan-client.sh" ]]; then
        timeout 45 "$(dirname "$0")/restore-wlan-client.sh" || log "WARN: wlan0 client restore failed"
    fi
}

setup_interface
start_services

# Do not block systemd ExecStart — nmcli can hang and prevent ExecStop on stop.
restore_wlan_client &

if [[ -x /usr/local/bin/restart-ap-streaming.sh ]]; then
    /usr/local/bin/restart-ap-streaming.sh || log "WARN: AP streaming restart failed"
elif [[ -x "$(dirname "$0")/restart-ap-streaming.sh" ]]; then
    "$(dirname "$0")/restart-ap-streaming.sh" || log "WARN: AP streaming restart failed"
fi

SSID="$(grep -E '^ssid=' "$HOSTAPD_CONF" 2>/dev/null | cut -d= -f2- || echo 'AP')"
log "AP ready: SSID ${SSID} on $AP ($AP_IP)"
