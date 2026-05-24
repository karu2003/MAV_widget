#!/bin/bash
# Install AP tray icon + toggle backend. Run: sudo ./scripts/install-ap-tray.sh

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_BIN="/usr/local/bin"
SUDOERS_FILE="/etc/sudoers.d/mav-widget-hotspot"
DESKTOP_USER="${SUDO_USER:-ubuntu}"
DESKTOP_HOME="$(getent passwd "${DESKTOP_USER}" | cut -d: -f6)"
DESKTOP_UID="$(id -u "${DESKTOP_USER}")"

install -m 755 "$PROJECT_DIR/scripts/toggle-ap.sh" "$INSTALL_BIN/toggle-ap.sh"
install -m 755 "$PROJECT_DIR/scripts/stop-ap-user.sh" "$INSTALL_BIN/stop-ap-user.sh"
install -m 755 "$PROJECT_DIR/scripts/stop-drone-hotspot.sh" "$INSTALL_BIN/stop-drone-hotspot.sh"
install -m 755 "$PROJECT_DIR/scripts/gcs-ap-manual-off.sh" "$INSTALL_BIN/gcs-ap-manual-off.sh"
install -m 755 "$PROJECT_DIR/scripts/restore-wlan-client.sh" "$INSTALL_BIN/restore-wlan-client.sh"
install -m 755 "$PROJECT_DIR/scripts/configure-wlan-client.sh" "$INSTALL_BIN/configure-wlan-client.sh"
install -m 755 "$PROJECT_DIR/scripts/check-gcs-link.sh" "$INSTALL_BIN/check-gcs-link.sh"
install -m 755 "$PROJECT_DIR/scripts/gcs-ap-tray.py" "$INSTALL_BIN/gcs-ap-tray.py"
mkdir -p /var/lib/gcs-ap

# Remove legacy desktop launchers (tray only)
rm -f "${DESKTOP_HOME}/Desktop/gcs-toggle-ap.desktop"
rm -f "${DESKTOP_HOME}/Desktop/gcs-ap-on.desktop" "${DESKTOP_HOME}/Desktop/gcs-ap-off.desktop"
rm -f "${DESKTOP_HOME}/Desktop/toggle-hotspot.desktop"
rm -f /usr/share/applications/gcs-toggle-ap.desktop
rm -f /usr/share/applications/gcs-ap-settings.desktop
rm -f /usr/local/bin/update-ap-desktop-icon.sh
rm -f /usr/local/bin/remove-ap-desktop.sh

if [[ ! -f "$SUDOERS_FILE" ]] || ! grep -q 'toggle-ap.sh' "$SUDOERS_FILE" 2>/dev/null; then
    cat >"$SUDOERS_FILE" <<'EOF'
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/toggle-ap.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/stop-ap-user.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/restore-wlan-client.sh
EOF
    chmod 440 "$SUDOERS_FILE"
fi

USER_UNIT_DIR="${DESKTOP_HOME}/.config/systemd/user"
mkdir -p "$USER_UNIT_DIR"
cp "$PROJECT_DIR/systemd/gcs-ap-tray.service" "${USER_UNIT_DIR}/"
chown "${DESKTOP_USER}:${DESKTOP_USER}" "${USER_UNIT_DIR}/gcs-ap-tray.service"
rm -f "${USER_UNIT_DIR}/gcs-ap-icon-refresh.service" "${USER_UNIT_DIR}/gcs-ap-icon-refresh.timer"

if [[ -d "/run/user/${DESKTOP_UID}" ]]; then
    pkill -f '/usr/local/bin/gcs-ap-tray.py' 2>/dev/null || true
    pkill -f 'MAV_widget/scripts/gcs-ap-tray.py' 2>/dev/null || true
    sudo -u "${DESKTOP_USER}" \
        XDG_RUNTIME_DIR="/run/user/${DESKTOP_UID}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${DESKTOP_UID}/bus" \
        systemctl --user disable --now gcs-ap-icon-refresh.timer 2>/dev/null || true
    sudo -u "${DESKTOP_USER}" \
        XDG_RUNTIME_DIR="/run/user/${DESKTOP_UID}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${DESKTOP_UID}/bus" \
        systemctl --user daemon-reload
    sudo -u "${DESKTOP_USER}" \
        XDG_RUNTIME_DIR="/run/user/${DESKTOP_UID}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${DESKTOP_UID}/bus" \
        systemctl --user enable --now gcs-ap-tray.service
fi

echo "Done. AP control: top panel tray icon only (right-click menu)."
