#!/bin/bash
# Verify GCS network: eth0=192.168.53.1, eth1=USB debug (DHCP).

set -euo pipefail

BUILTIN_MAC="00:55:7b:b5:7d:f7"
USB_MAC="00:60:6e:b9:ce:28"
RADIO_IP="192.168.53.1/24"

ok=0
fail=0

pass() { echo "  OK   $*"; ((ok++)) || true; }
bad()  { echo "  FAIL $*"; ((fail++)) || true; }

mac_of() {
    cat "/sys/class/net/$1/address" 2>/dev/null || echo ""
}

echo "=== GCS network check ==="
echo ""

if ip link show eth0 &>/dev/null; then
    m="$(mac_of eth0)"
    if [[ "${m,,}" == "${BUILTIN_MAC}" ]]; then
        pass "eth0 MAC $m (built-in radio port)"
    else
        bad "eth0 MAC $m (expected $BUILTIN_MAC) — run: sudo setup-network.sh"
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
    if [[ "${m,,}" == "${USB_MAC}" ]]; then
        pass "eth1 MAC $m (USB debug adapter)"
    else
        bad "eth1 MAC $m (expected $USB_MAC)"
    fi
    pass "eth1 address $(ip -br addr show eth1 | awk '{print $3}') (DHCP ok)"
else
    echo "  WARN eth1 not present (USB unplugged?)"
fi

echo ""
nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | while IFS=: read -r name dev; do
    [[ "$dev" == "eth0" || "$dev" == "eth1" ]] && echo "  NM: $name -> $dev"
done
echo ""
echo "=== Summary: OK=$ok FAIL=$fail ==="
(( fail == 0 ))
