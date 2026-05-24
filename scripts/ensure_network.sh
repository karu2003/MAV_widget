#!/bin/bash
# Ensure built-in port is eth0 with 192.168.53.1; USB is eth1 (DHCP).

set -euo pipefail

BUILTIN_MAC="00:55:7b:b5:7d:f7"
USB_MAC="00:60:6e:b9:ce:28"
RADIO_IP="192.168.53.1/24"

log() { echo "[ensure-network] $*"; }

mac_of() {
    tr '[:upper:]' '[:lower:]' < "/sys/class/net/$1/address" 2>/dev/null || true
}

delete_generic_wired() {
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        nmcli connection delete "$name" 2>/dev/null || true
        log "Removed generic profile: $name"
    done < <(nmcli -t -f NAME connection show 2>/dev/null | grep -E '^Wired connection ' || true)
}

names_correct() {
    ip link show eth0 &>/dev/null || return 1
    ip link show eth1 &>/dev/null || return 1
    [[ "$(mac_of eth0)" == "$BUILTIN_MAC" && "$(mac_of eth1)" == "$USB_MAC" ]]
}

swap_eth_names() {
    log "Renaming: built-in -> eth0, USB -> eth1"
    systemctl stop NetworkManager
    ip link set eth0 down 2>/dev/null || true
    ip link set eth1 down 2>/dev/null || true
    ip link set eth0 name eth_gcs_tmp
    ip link set eth1 name eth0
    ip link set eth_gcs_tmp name eth1
    ip link set eth0 up
    ip link set eth1 up
    systemctl start NetworkManager
    sleep 3
}

apply_profiles() {
    nmcli connection reload
    nmcli connection up "GCS-Radio" ifname eth0 2>/dev/null || \
        nmcli connection up "GCS-Radio" 2>/dev/null || true
    nmcli connection up "USB-Debug" ifname eth1 2>/dev/null || \
        nmcli connection up "USB-Debug" 2>/dev/null || true

    if ! ip -br addr show eth0 2>/dev/null | grep -q "$RADIO_IP"; then
        log "Fallback: ip addr add $RADIO_IP dev eth0"
        ip addr flush dev eth0 2>/dev/null || true
        ip addr add "$RADIO_IP" dev eth0
        ip link set eth0 up
    fi
}

delete_generic_wired

if names_correct && ip -br addr show eth0 | grep -q "$RADIO_IP"; then
    log "Network OK"
    exit 0
fi

if ip link show eth0 &>/dev/null && ip link show eth1 &>/dev/null; then
    if [[ "$(mac_of eth0)" == "$USB_MAC" && "$(mac_of eth1)" == "$BUILTIN_MAC" ]]; then
        swap_eth_names
    fi
fi

apply_profiles

if names_correct && ip -br addr show eth0 | grep -q "$RADIO_IP"; then
    log "Network fixed: eth0=$(ip -br addr show eth0) eth1=$(ip -br addr show eth1 2>/dev/null || echo n/a)"
    exit 0
fi

log "WARN: could not verify eth0=$RADIO_IP — reboot may be required for .link rules"
exit 1
