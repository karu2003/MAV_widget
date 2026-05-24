#!/bin/bash
# NAT: internet via wlan0 + eth1 → clients on uap0 (AP) and eth0 (192.168.53.0/24).

set -euo pipefail

# Internet sources (uplinks)
UPLINK_IFS=(wlan0 eth1)
# Recipients of internet (LAN interfaces)
RECIPIENT_IFS=(uap0 eth0)

AP_GW="${AP_GW:-192.168.54.1}"
RULES_FILE="${RULES_FILE:-/etc/iptables/rules.v4}"
DNSMASQ_SNIPPET="${DNSMASQ_SNIPPET:-/etc/dnsmasq.d/drone-hotspot.conf}"

log() { echo "[setup-nat] $*"; }

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

if ! command -v iptables >/dev/null; then
    echo "iptables not found" >&2
    exit 1
fi

log "Uplinks (internet): ${UPLINK_IFS[*]}"
log "Recipients:         ${RECIPIENT_IFS[*]} (AP + 192.168.53.0/24)"

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null || true
for ifc in "${RECIPIENT_IFS[@]}" "${UPLINK_IFS[@]}"; do
    sysctl -w "net.ipv4.conf.${ifc}.rp_filter=0" >/dev/null 2>&1 || true
done

iptables -F FORWARD
iptables -t nat -F POSTROUTING

for uplink in "${UPLINK_IFS[@]}"; do
    if ! ip link show "$uplink" &>/dev/null; then
        log "Skip uplink $uplink (interface missing)"
        continue
    fi
    iptables -t nat -A POSTROUTING -o "$uplink" -j MASQUERADE
    log "MASQUERADE -o $uplink"
    for recipient in "${RECIPIENT_IFS[@]}"; do
        if ! ip link show "$recipient" &>/dev/null; then
            log "Skip $recipient -> $uplink (recipient missing)"
            continue
        fi
        iptables -A FORWARD -i "$recipient" -o "$uplink" -j ACCEPT
        iptables -A FORWARD -i "$uplink" -o "$recipient" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        log "FORWARD $recipient -> $uplink (+ established return)"
    done
done

# Local: AP clients may reach drone radio subnet directly (no NAT).
if ip link show uap0 &>/dev/null && ip link show eth0 &>/dev/null; then
    iptables -A FORWARD -i uap0 -o eth0 -j ACCEPT
    iptables -A FORWARD -i eth0 -o uap0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    log "FORWARD uap0 <-> eth0 (local MAVLink / drone subnet)"
fi

if command -v netfilter-persistent >/dev/null; then
    netfilter-persistent save
    log "Saved via netfilter-persistent"
elif command -v iptables-save >/dev/null; then
    iptables-save > "$RULES_FILE"
    log "Saved $RULES_FILE"
fi

if [[ -f "$DNSMASQ_SNIPPET" ]]; then
    if ! grep -q 'option:router' "$DNSMASQ_SNIPPET"; then
        echo "dhcp-option=option:router,${AP_GW}" >> "$DNSMASQ_SNIPPET"
        log "Added DHCP router ${AP_GW} to $DNSMASQ_SNIPPET"
    fi
    if systemctl is-active --quiet dnsmasq; then
        systemctl restart dnsmasq
    fi
else
    log "dnsmasq snippet not found: $DNSMASQ_SNIPPET"
fi

log "Done. Verify: check-nat.sh"
