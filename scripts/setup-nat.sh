#!/bin/bash
# NAT: internet via INTERNET_IFS → clients on uap0 (AP) and the radio subnet.
# Interface roles are read from /etc/default/gcs-ap-streaming (RADIO_IF,
# INTERNET_IFS). Defaults keep the original board behaviour (radio=eth0,
# internet via wlan0/eth1); Winmate sets RADIO_IF=usb0, INTERNET_IFS="eth0 wlan0".

set -euo pipefail

CONF="${GCS_STREAMING_CONF:-/etc/default/gcs-ap-streaming}"
if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CONF"
fi

RADIO_IF="${RADIO_IF:-eth0}"
# Internet sources (uplinks) — from INTERNET_IFS, else legacy default.
read -r -a UPLINK_IFS <<< "${INTERNET_IFS:-wlan0 eth1}"
# Recipients of internet: AP clients + the radio subnet (drone/companion).
RECIPIENT_IFS=(uap0 "$RADIO_IF")

AP_GW="${AP_GW:-192.168.54.1}"
AP_NET="${AP_NET:-192.168.54.0/24}"
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

# Local: AP clients may reach drone radio subnet. MASQUERADE makes replies work
# even when ArduPilot/sonar do not have a route back to 192.168.54.0/24.
if ip link show uap0 &>/dev/null && ip link show "$RADIO_IF" &>/dev/null; then
    iptables -t nat -A POSTROUTING -s "$AP_NET" -o "$RADIO_IF" -j MASQUERADE
    iptables -A FORWARD -i uap0 -o "$RADIO_IF" -j ACCEPT
    iptables -A FORWARD -i "$RADIO_IF" -o uap0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    log "MASQUERADE ${AP_NET} -> ${RADIO_IF} (phone -> drone subnet)"
    log "FORWARD uap0 <-> ${RADIO_IF} (local MAVLink / drone subnet)"
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
