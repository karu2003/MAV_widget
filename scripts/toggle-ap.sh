#!/bin/bash
# Toggle drone AP (drone-hotspot.service: uap0 + hostapd + dnsmasq).
# Self-elevates to root — used by tray icon and CLI.

set -uo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    exec sudo /usr/local/bin/toggle-ap.sh "$@"
fi

DESKTOP_USER="${SUDO_USER:-ubuntu}"
DESKTOP_UID="$(id -u "${DESKTOP_USER}" 2>/dev/null || echo 1000)"
RUNTIME="/run/user/${DESKTOP_UID}"

SSID="$(grep -E '^ssid=' /etc/hostapd/drone-hotspot.conf 2>/dev/null | cut -d= -f2- || echo 'AP')"
AP_IP="192.168.54.1"
STOP_USER="${GCS_AP_STOP_USER:-/usr/local/bin/stop-ap-user.sh}"

notify() {
    echo "[toggle-ap] $1"
    if [[ ! -d "$RUNTIME" ]] || ! command -v notify-send >/dev/null; then
        return 0
    fi
    sudo -u "${DESKTOP_USER}" \
        DISPLAY="${DISPLAY:-:0}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=${RUNTIME}/bus" \
        notify-send -i "${2:-network-wireless}" "GCS Wi-Fi AP" "$1" 2>/dev/null || true
}

ap_running() {
    systemctl is-active --quiet hostapd 2>/dev/null && ip link show uap0 &>/dev/null
}

wait_ap_state() {
    local expect_on="$1"
    local timeout="${2:-25}"
    local i
    for ((i = 0; i < timeout; i++)); do
        if ap_running; then
            [[ "$expect_on" == "1" ]] && return 0
        else
            [[ "$expect_on" == "0" ]] && return 0
        fi
        sleep 1
    done
    return 1
}

stop_ap() {
    if [[ -x "$STOP_USER" ]]; then
        "$STOP_USER"
    else
        /usr/local/bin/gcs-ap-manual-off.sh off
        /usr/local/bin/stop-drone-hotspot.sh
        systemctl stop drone-hotspot.service 2>/dev/null || true
        systemctl reset-failed drone-hotspot.service 2>/dev/null || true
    fi
}

start_ap() {
    rm -f /var/lib/gcs-ap/manual-off
    systemctl reset-failed drone-hotspot.service 2>/dev/null || true
    systemctl restart drone-hotspot.service
}

if ap_running; then
    stop_ap
    if wait_ap_state 0 20; then
        notify "AP off (${SSID})" "gcs-ap-off"
    else
        notify "AP stop incomplete — run: journalctl -u drone-hotspot -b" "dialog-warning"
    fi
else
    start_ap
    if wait_ap_state 1 30; then
        notify "AP on: ${SSID}  ${AP_IP}" "gcs-ap-on"
    else
        notify "Failed to start AP — see: journalctl -u drone-hotspot -b" "dialog-warning"
        exit 1
    fi
fi
