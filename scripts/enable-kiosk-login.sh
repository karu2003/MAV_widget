#!/bin/bash
# Winmate GCS kiosk: no password at boot and no lock after idle.
#
# 1. GDM autologin for ubuntu (needs root)
# 2. GNOME screen lock + idle suspend off (toggle-screen-lock.sh)
#
# Usage:
#   ./enable-kiosk-login.sh          # screen lock only (no sudo)
#   sudo ./enable-kiosk-login.sh     # autologin + screen lock
#   ./enable-kiosk-login.sh status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GDM_CONF="/etc/gdm3/custom.conf"
USER_NAME="${KIOSK_USER:-ubuntu}"

log() { printf '[kiosk-login] %s\n' "$*"; }

enable_gdm_autologin() {
    if [[ "${EUID}" -ne 0 ]]; then
        log "Skip GDM autologin (run with sudo for boot login without password)"
        return 0
    fi
    if [[ ! -f "$GDM_CONF" ]]; then
        log "ERROR: $GDM_CONF not found"
        exit 1
    fi
    cp -a "$GDM_CONF" "${GDM_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    if grep -q '^AutomaticLoginEnable=' "$GDM_CONF"; then
        sed -i "s/^AutomaticLoginEnable=.*/AutomaticLoginEnable=true/" "$GDM_CONF"
    else
        sed -i "/^\[daemon\]/a AutomaticLoginEnable=true" "$GDM_CONF"
    fi
    if grep -q '^AutomaticLogin=' "$GDM_CONF"; then
        sed -i "s/^AutomaticLogin=.*/AutomaticLogin=${USER_NAME}/" "$GDM_CONF"
    else
        sed -i "/^\[daemon\]/a AutomaticLogin=${USER_NAME}" "$GDM_CONF"
    fi
    log "OK: GDM autologin enabled for ${USER_NAME}"
}

disable_gdm_autologin() {
    if [[ "${EUID}" -ne 0 ]]; then
        log "Need sudo to disable GDM autologin"
        exit 1
    fi
    sed -i 's/^AutomaticLoginEnable=.*/AutomaticLoginEnable=false/' "$GDM_CONF"
    log "GDM autologin disabled"
}

cmd="${1:-enable}"

case "$cmd" in
    enable|on|off-disable)
        enable_gdm_autologin
        "$SCRIPT_DIR/toggle-screen-lock.sh" off
        log "Done. Reboot to apply autologin at boot (if sudo was used)."
        ;;
    disable|restore)
        disable_gdm_autologin
        "$SCRIPT_DIR/toggle-screen-lock.sh" on
        ;;
    status)
        "$SCRIPT_DIR/toggle-screen-lock.sh" status
        echo ""
        if [[ -f "$GDM_CONF" ]]; then
            echo "GDM autologin:"
            grep -E '^AutomaticLogin' "$GDM_CONF" || echo "  (not configured)"
        fi
        ;;
    *)
        echo "Usage: $0 [enable|disable|status]" >&2
        exit 1
        ;;
esac
