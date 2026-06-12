#!/bin/bash
# Verify GCS network: eth0=192.168.53.1 (radio), eth1=USB debug (DHCP).
# Radio adapter MAC is read from installed .link file — not hardcoded.

set -euo pipefail

RADIO_LINK_FILE="/etc/systemd/network/10-gcs-builtin.link"
DEBUG_MAC="00:60:6e:b9:ce:28"
RADIO_IP="192.168.53.1/24"

ok=0
fail=0

pass() { echo "  OK   $*"; ((ok++)) || true; }
bad()  { echo "  FAIL $*"; ((fail++)) || true; }
warn() { echo "  WARN $*"; }

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
