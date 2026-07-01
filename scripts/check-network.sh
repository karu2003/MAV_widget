#!/bin/bash
# Verify GCS network: radio link = 192.168.53.1, USB debug = DHCP.
# Default board: radio=eth0 (USB-ETH renamed via .link). Winmate: RADIO_IF=usb0.

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

ok=0
fail=0

pass() { echo "  OK   $*"; ((ok++)) || true; }
bad()  { echo "  FAIL $*"; ((fail++)) || true; }
warn() { echo "  WARN $*"; }

# Built-in radio (e.g. Winmate usb0): no adapter renaming, eth0 stays as WAN.
if [[ "$RADIO_BUILTIN" == "1" ]]; then
    echo "=== GCS network check (built-in radio ${RADIO_IF}) ==="
    echo ""
    if ip link show "$RADIO_IF" &>/dev/null; then
        addr="$(ip -br addr show "$RADIO_IF" | awk '{print $3}')"
        if [[ "$addr" == "$RADIO_IP" ]]; then
            pass "${RADIO_IF} address $addr"
        else
            bad "${RADIO_IF} address ${addr:-none} (expected $RADIO_IP)"
        fi
        if ip route show dev "$RADIO_IF" | grep -q '^default'; then
            bad "${RADIO_IF} has default route (should be never-default)"
        else
            pass "${RADIO_IF} no default route"
        fi
        # Radio subnet must route out RADIO_IF (lowest metric), not a stray iface.
        r_if="$(ip route show 192.168.53.0/24 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')"
        if [[ "$r_if" == "$RADIO_IF" ]]; then
            pass "192.168.53.0/24 routed via ${RADIO_IF}"
        else
            warn "192.168.53.0/24 routed via ${r_if:-none} (expected ${RADIO_IF})"
        fi
    else
        bad "${RADIO_IF} missing"
    fi
    echo ""
    echo "=== Summary: OK=$ok FAIL=$fail ==="
    [[ "$fail" -eq 0 ]] && exit 0 || exit 1
fi

mac_of() {
    cat "/sys/class/net/$1/address" 2>/dev/null || echo ""
}

# Read expected radio MAC from installed .link file (set by setup_network.sh)
BUILTIN_MAC=""
if [[ -f "$RADIO_LINK_FILE" ]]; then
    BUILTIN_MAC=$(grep -i '^MACAddress=' "$RADIO_LINK_FILE" | head -1 | \
        cut -d= -f2 | tr '[:upper:]' '[:lower:]' | tr -d ' \r')
fi

echo "=== GCS network check ==="
echo ""

if ip link show eth0 &>/dev/null; then
    m="$(mac_of eth0)"
    if [[ -n "$BUILTIN_MAC" ]]; then
        if [[ "${m,,}" == "${BUILTIN_MAC,,}" ]]; then
            pass "eth0 MAC $m (radio adapter)"
        else
            warn "eth0 MAC $m (expected $BUILTIN_MAC from $RADIO_LINK_FILE) — reinstall: sudo setup_network.sh"
        fi
    else
        warn "eth0 MAC $m (expected MAC unknown — file $RADIO_LINK_FILE not found)"
    fi
    addr="$(ip -br addr show eth0 | awk '{print $3}')"
    if [[ "$addr" == "$RADIO_IP" ]]; then
        pass "eth0 address $addr"
    else
        bad "eth0 address ${addr:-none} (expected $RADIO_IP)"
    fi
    if ip route show dev eth0 | grep -q '^default'; then
        bad "eth0 has default route (should be never-default)"
    else
        pass "eth0 no default route"
    fi
else
    bad "eth0 missing"
fi

if ip link show eth1 &>/dev/null; then
    m="$(mac_of eth1)"
    if [[ "${m,,}" == "${DEBUG_MAC,,}" ]]; then
        pass "eth1 MAC $m (USB debug adapter)"
    else
        warn "eth1 MAC $m (expected $DEBUG_MAC)"
    fi
    pass "eth1 address $(ip -br addr show eth1 | awk '{print $3}') (DHCP ok)"
else
    warn "eth1 not present (USB debug unplugged?)"
fi

echo ""
nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | while IFS=: read -r name dev; do
    [[ "$dev" == "eth0" || "$dev" == "eth1" ]] && echo "  NM: $name -> $dev"
done
echo ""
echo "=== Summary: OK=$ok FAIL=$fail ==="
(( fail == 0 ))
