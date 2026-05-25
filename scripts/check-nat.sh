#!/bin/bash
# Verify NAT: wlan0 + eth1 → internet; uap0 (AP) + eth0 (192.168.53.x) → recipients.

set -euo pipefail

UPLINK_IFS=(wlan0 eth1)
RECIPIENT_IFS=(uap0 eth0)
AP_NET="${AP_NET:-192.168.54.0/24}"
RADIO_IF="${RADIO_IF:-eth0}"

ok=0
warn=0
fail=0

pass() { echo "  OK   $*"; ((ok++)) || true; }
note() { echo "  WARN $*"; ((warn++)) || true; }
bad()  { echo "  FAIL $*"; ((fail++)) || true; }

# iptables requires root; setup-nat runs as root, check must too.
iptables_cmd() {
    if [[ "${EUID}" -eq 0 ]]; then
        iptables "$@"
    else
        sudo iptables "$@"
    fi
}

echo "=== NAT / forwarding check ==="
echo "Internet sources (uplinks):  ${UPLINK_IFS[*]}"
echo "Internet recipients (LANs):  ${RECIPIENT_IFS[*]}  (AP + 192.168.53.0/24 via eth0)"
echo ""
for ifc in "${UPLINK_IFS[@]}" "${RECIPIENT_IFS[@]}"; do
    echo "  $ifc  $(ip -br addr show "$ifc" 2>/dev/null || echo 'missing')"
done
echo ""

echo "--- Kernel ---"
if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]]; then
    pass "net.ipv4.ip_forward=1"
else
    bad "net.ipv4.ip_forward is not 1"
fi
echo ""

echo "--- Live iptables (via sudo) ---"
if ! command -v iptables >/dev/null; then
    bad "iptables not installed"
else
    if ! iptables_cmd -t nat -L POSTROUTING -n &>/dev/null; then
        bad "Cannot read iptables (try: sudo $0)"
    else
        nat_lines="$(iptables_cmd -t nat -S POSTROUTING 2>/dev/null | grep -v '^-N' || true)"
        fwd_lines="$(iptables_cmd -S FORWARD 2>/dev/null | grep -v '^-N' || true)"
        if [[ -z "$nat_lines" && -z "$fwd_lines" ]]; then
            bad "No NAT/FORWARD rules loaded — run: sudo setup-nat.sh"
        fi

        for uplink in "${UPLINK_IFS[@]}"; do
            if ! ip link show "$uplink" &>/dev/null; then
                note "Uplink $uplink missing (rules may still be preconfigured)"
                continue
            fi
            if iptables_cmd -t nat -C POSTROUTING -o "$uplink" -j MASQUERADE 2>/dev/null; then
                pass "MASQUERADE -o $uplink"
            else
                bad "Missing MASQUERADE -o $uplink"
            fi
            for recipient in "${RECIPIENT_IFS[@]}"; do
                if ! ip link show "$recipient" &>/dev/null; then
                    continue
                fi
                if iptables_cmd -C FORWARD -i "$recipient" -o "$uplink" -j ACCEPT 2>/dev/null; then
                    pass "FORWARD $recipient -> $uplink"
                else
                    bad "Missing FORWARD $recipient -> $uplink"
                fi
            done
        done

        if ip link show uap0 &>/dev/null && ip link show "$RADIO_IF" &>/dev/null; then
            if iptables_cmd -t nat -C POSTROUTING -s "$AP_NET" -o "$RADIO_IF" -j MASQUERADE 2>/dev/null; then
                pass "MASQUERADE ${AP_NET} -> ${RADIO_IF} (phone reaches drone subnet)"
            else
                bad "Missing MASQUERADE ${AP_NET} -> ${RADIO_IF} (phone ping to 192.168.53.x may fail)"
            fi
            if iptables_cmd -C FORWARD -i uap0 -o "$RADIO_IF" -j ACCEPT 2>/dev/null; then
                pass "FORWARD uap0 -> ${RADIO_IF}"
            else
                bad "Missing FORWARD uap0 -> ${RADIO_IF}"
            fi
        fi

        echo "$nat_lines"
        echo "$fwd_lines"
    fi
fi
echo ""

echo "--- Saved rules (/etc/iptables/rules.v4) ---"
if [[ -f /etc/iptables/rules.v4 ]]; then
    for uplink in "${UPLINK_IFS[@]}"; do
        if grep -qE "\-o ${uplink} -j MASQUERADE" /etc/iptables/rules.v4 2>/dev/null; then
            pass "rules.v4: MASQUERADE $uplink"
        else
            note "rules.v4: no MASQUERADE for $uplink"
        fi
    done
else
    note "No /etc/iptables/rules.v4"
fi
echo ""

echo "--- dnsmasq (AP gateway 192.168.54.1) ---"
router_line="$(grep -rh 'option:router' /etc/dnsmasq.d/ 2>/dev/null | grep -v '^[[:space:]]*#' | head -1 || true)"
if [[ -n "$router_line" ]]; then
    pass "DHCP: $router_line"
else
    bad "No dhcp-option=option:router for AP clients"
fi
echo ""
echo "Note: 192.168.53.x devices must use 192.168.53.1 as default gateway (static on radio link)."
echo ""

echo "=== Summary: OK=$ok WARN=$warn FAIL=$fail ==="
if (( fail > 0 )); then
    echo "Fix: sudo setup-nat.sh && sudo check-nat.sh"
    exit 1
fi
exit 0
