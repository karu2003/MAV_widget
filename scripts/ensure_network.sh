#!/bin/bash
# Ensure radio port is eth0 with 192.168.53.1; USB-debug is eth1 (DHCP).
# Radio adapter MAC is read from the installed .link file — not hardcoded.

set -euo pipefail

RADIO_LINK_FILE="/etc/systemd/network/10-gcs-builtin.link"
DEBUG_MAC="00:60:6e:b9:ce:28"
RADIO_IP="192.168.53.1/24"

log() { echo "[ensure-network] $*"; }

mac_of() {
    tr '[:upper:]' '[:lower:]' < "/sys/class/net/$1/address" 2>/dev/null || true
}

# Read radio MAC from installed .link file (written by setup_network.sh)
radio_mac_from_link() {
    if [[ -f "$RADIO_LINK_FILE" ]]; then
        grep -i '^MACAddress=' "$RADIO_LINK_FILE" | head -1 | cut -d= -f2 | \
            tr '[:upper:]' '[:lower:]' | tr -d ' \r'
    fi
}

BUILTIN_MAC=$(radio_mac_from_link)

delete_generic_wired() {
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        nmcli connection delete "$name" 2>/dev/null || true
        log "Removed generic profile: $name"
    done < <(nmcli -t -f NAME connection show 2>/dev/null | grep -E '^Wired connection ' || true)
}

# eth0 is correct if it exists and has the right IP (MAC check is optional — only if known)
eth0_ok() {
    ip link show eth0 &>/dev/null || return 1
    ip -br addr show eth0 2>/dev/null | grep -q "$RADIO_IP"
}

swap_eth_names() {
    log "Renaming interfaces: radio -> eth0, debug -> eth1"
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

if eth0_ok; then
    log "Network OK"
    exit 0
fi

# If we know both MACs, try to swap misnamed interfaces
if [[ -n "$BUILTIN_MAC" ]] && \
   ip link show eth0 &>/dev/null && ip link show eth1 &>/dev/null; then
    if [[ "$(mac_of eth0)" == "${DEBUG_MAC,,}" && \
          "$(mac_of eth1)" == "${BUILTIN_MAC,,}" ]]; then
        swap_eth_names
    fi
fi

# Try swap by detecting which of eth0/eth1 is the debug adapter
if ! eth0_ok && \
   ip link show eth0 &>/dev/null && ip link show eth1 &>/dev/null; then
    if [[ "$(mac_of eth0)" == "${DEBUG_MAC,,}" ]]; then
        swap_eth_names
    fi
fi

apply_profiles

if eth0_ok; then
    log "Network fixed: eth0=$(ip -br addr show eth0) eth1=$(ip -br addr show eth1 2>/dev/null || echo n/a)"
    exit 0
fi

log "WARN: could not verify eth0=$RADIO_IP — reboot may be required for .link rules"
exit 1
