#!/bin/bash
# Ensure radio port is eth0 with 192.168.53.1; USB-debug is eth1 (DHCP).
# Radio adapter MAC is read from the installed .link file — not hardcoded.
# Handles USB adapters that may appear under any name (enx..., eth1, etc.).

set -euo pipefail

CONF="${GCS_STREAMING_CONF:-/etc/default/gcs-ap-streaming}"
if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CONF"
fi

RADIO_LINK_FILE="/etc/systemd/network/10-gcs-builtin.link"
DEBUG_MAC="00:60:6e:b9:ce:28"
RADIO_IF="${RADIO_IF:-eth0}"
RADIO_IP="${RADIO_IP:-192.168.53.1/24}"
RADIO_BUILTIN="${RADIO_BUILTIN:-0}"
RADIO_PROFILE="${RADIO_PROFILE:-Microhard-Host}"

log() { echo "[ensure-network] $*"; }

# Built-in radio (e.g. Winmate usb0): ensure IP on RADIO_IF, never rename eth0.
if [[ "$RADIO_BUILTIN" == "1" ]]; then
    if ! ip link show "$RADIO_IF" &>/dev/null; then
        log "ERROR: radio interface $RADIO_IF not present"
        exit 1
    fi
    if ip -br addr show "$RADIO_IF" 2>/dev/null | grep -q "${RADIO_IP%/*}"; then
        log "Radio OK: $RADIO_IF has $RADIO_IP"
    else
        log "Bringing up $RADIO_IF with $RADIO_IP"
        if nmcli -t -f NAME connection show 2>/dev/null | grep -qxF "$RADIO_PROFILE"; then
            nmcli connection up "$RADIO_PROFILE" ifname "$RADIO_IF" 2>/dev/null \
                || nmcli connection up "$RADIO_PROFILE" 2>/dev/null || true
        fi
        if ! ip -br addr show "$RADIO_IF" 2>/dev/null | grep -q "${RADIO_IP%/*}"; then
            log "Fallback: ip addr add $RADIO_IP dev $RADIO_IF"
            ip addr add "$RADIO_IP" dev "$RADIO_IF" 2>/dev/null || true
            ip link set "$RADIO_IF" up 2>/dev/null || true
        fi
    fi
    # Radio link must never provide the default route.
    ip route del default dev "$RADIO_IF" 2>/dev/null || true
    exit 0
fi

# Lowercase MAC of an interface (empty string if interface absent)
mac_of() {
    tr '[:upper:]' '[:lower:]' < "/sys/class/net/$1/address" 2>/dev/null || true
}

# Find the first interface whose MAC matches the given value (any current name)
iface_with_mac() {
    local target="${1,,}"
    for iface in $(ls /sys/class/net/); do
        local m
        m=$(mac_of "$iface")
        [[ "$m" == "$target" ]] && echo "$iface" && return 0
    done
    return 1
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

# eth0 is correct if it exists and already has the radio IP
eth0_ok() {
    ip link show eth0 &>/dev/null || return 1
    ip -br addr show eth0 2>/dev/null | grep -q "$RADIO_IP"
}

# Rename $1 -> eth0 (displacing whatever is currently named eth0, if anything)
rename_to_eth0() {
    local src="$1"
    [[ "$src" == "eth0" ]] && return 0

    log "Renaming $src -> eth0 (current name may be USB default like enx...)"
    systemctl stop NetworkManager

    # If something else is already called eth0, move it out of the way first
    if ip link show eth0 &>/dev/null; then
        ip link set eth0 down 2>/dev/null || true
        ip link set eth0 name eth_gcs_tmp
    fi

    ip link set "$src" down 2>/dev/null || true
    ip link set "$src" name eth0
    ip link set eth0 up

    # Restore the displaced interface as eth1
    if ip link show eth_gcs_tmp &>/dev/null; then
        ip link set eth_gcs_tmp name eth1 2>/dev/null || true
        ip link set eth1 up 2>/dev/null || true
    fi

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

# --- Try to fix naming ---
# Strategy 1: we know the radio MAC — find it wherever it is and rename to eth0
if [[ -n "$BUILTIN_MAC" ]]; then
    radio_iface=$(iface_with_mac "$BUILTIN_MAC" || true)
    if [[ -n "$radio_iface" && "$radio_iface" != "eth0" ]]; then
        log "Radio adapter found as $radio_iface (MAC=$BUILTIN_MAC), renaming to eth0"
        rename_to_eth0 "$radio_iface"
    fi
fi

# Strategy 2: radio MAC unknown — find the non-debug ethernet and rename it to eth0
if ! eth0_ok && [[ -z "$BUILTIN_MAC" ]]; then
    for iface in $(ls /sys/class/net/); do
        [[ -e "/sys/class/net/$iface/device" ]] || continue
        [[ -d "/sys/class/net/$iface/wireless" ]] && continue
        [[ "$iface" == "eth0" ]] && continue
        m=$(mac_of "$iface")
        [[ "${m}" == "${DEBUG_MAC,,}" ]] && continue
        log "Radio adapter candidate: $iface (MAC=$m), renaming to eth0"
        rename_to_eth0 "$iface"
        break
    done
fi

# Strategy 3: eth0 exists but debug MAC is on it — the real radio must be elsewhere
if ! eth0_ok && ip link show eth0 &>/dev/null; then
    if [[ "$(mac_of eth0)" == "${DEBUG_MAC,,}" ]]; then
        debug_iface="eth0"
        for iface in $(ls /sys/class/net/); do
            [[ -e "/sys/class/net/$iface/device" ]] || continue
            [[ -d "/sys/class/net/$iface/wireless" ]] && continue
            [[ "$iface" == "eth0" ]] && continue
            m=$(mac_of "$iface")
            [[ "${m}" == "${DEBUG_MAC,,}" ]] && continue
            log "Debug adapter on eth0; radio adapter is $iface, swapping"
            rename_to_eth0 "$iface"
            break
        done
    fi
fi

apply_profiles

if eth0_ok; then
    log "Network fixed: eth0=$(ip -br addr show eth0) eth1=$(ip -br addr show eth1 2>/dev/null || echo n/a)"
    exit 0
fi

log "WARN: could not verify eth0=$RADIO_IP — reboot may be required for .link rules"
exit 1
