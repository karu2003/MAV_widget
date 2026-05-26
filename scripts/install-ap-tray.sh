#!/bin/bash
# Install AP tray icon + toggle backend. Run: sudo ./scripts/install-ap-tray.sh

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_BIN="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
SUDOERS_FILE="/etc/sudoers.d/mav-widget-hotspot"
DESKTOP_USER="${SUDO_USER:-ubuntu}"
DESKTOP_HOME="$(getent passwd "${DESKTOP_USER}" | cut -d: -f6)"
DESKTOP_UID="$(id -u "${DESKTOP_USER}")"

install -m 755 "$PROJECT_DIR/scripts/toggle-ap.sh" "$INSTALL_BIN/toggle-ap.sh"
install -m 755 "$PROJECT_DIR/scripts/install-ap-tray.sh" "$INSTALL_BIN/install-ap-tray.sh"
install -m 755 "$PROJECT_DIR/scripts/start-drone-hotspot.sh" "$INSTALL_BIN/start-drone-hotspot.sh"
install -m 755 "$PROJECT_DIR/scripts/stop-ap-user.sh" "$INSTALL_BIN/stop-ap-user.sh"
install -m 755 "$PROJECT_DIR/scripts/stop-drone-hotspot.sh" "$INSTALL_BIN/stop-drone-hotspot.sh"
install -m 755 "$PROJECT_DIR/scripts/gcs-ap-manual-off.sh" "$INSTALL_BIN/gcs-ap-manual-off.sh"
install -m 755 "$PROJECT_DIR/scripts/fix-wlan-after-ap.sh" "$INSTALL_BIN/fix-wlan-after-ap.sh"
install -m 755 "$PROJECT_DIR/scripts/wlan-concurrent.sh" "$INSTALL_BIN/wlan-concurrent.sh"
install -m 755 "$PROJECT_DIR/scripts/wlan-concurrent-keepalive.sh" "$INSTALL_BIN/wlan-concurrent-keepalive.sh"
install -m 755 "$PROJECT_DIR/scripts/restore-wlan-client.sh" "$INSTALL_BIN/restore-wlan-client.sh"
install -m 755 "$PROJECT_DIR/scripts/setup-nat.sh" "$INSTALL_BIN/setup-nat.sh"
install -m 755 "$PROJECT_DIR/scripts/check-nat.sh" "$INSTALL_BIN/check-nat.sh"
install -m 755 "$PROJECT_DIR/scripts/cleanup-nm-wifi-duplicates.sh" "$INSTALL_BIN/cleanup-nm-wifi-duplicates.sh"
install -m 755 "$PROJECT_DIR/scripts/ensure-hostapd-concurrent.sh" "$INSTALL_BIN/ensure-hostapd-concurrent.sh"
install -m 755 "$PROJECT_DIR/scripts/configure-wlan-client.sh" "$INSTALL_BIN/configure-wlan-client.sh"
install -m 755 "$PROJECT_DIR/scripts/gcs-ap-tray.py" "$INSTALL_BIN/gcs-ap-tray.py"
mkdir -p /var/lib/gcs-ap
touch /var/lib/gcs-ap/manual-off

install -m 644 "$PROJECT_DIR/systemd/drone-hotspot.service" "$SYSTEMD_DIR/drone-hotspot.service"
install -m 644 "$PROJECT_DIR/systemd/gcs-ap-default-off.service" "$SYSTEMD_DIR/gcs-ap-default-off.service"
install -m 644 "$PROJECT_DIR/systemd/gcs-wlan-keepalive.service" "$SYSTEMD_DIR/gcs-wlan-keepalive.service"
install -m 644 "$PROJECT_DIR/systemd/gcs-wlan-keepalive.timer" "$SYSTEMD_DIR/gcs-wlan-keepalive.timer"
systemctl daemon-reload
systemctl enable gcs-ap-default-off.service
systemctl start gcs-ap-default-off.service
# AP must never auto-start on boot. toggle-ap.sh starts drone-hotspot explicitly.
systemctl disable drone-hotspot.service 2>/dev/null || true
systemctl stop drone-hotspot.service 2>/dev/null || true
"$INSTALL_BIN/stop-drone-hotspot.sh" --no-restore 2>/dev/null || true

install -m 755 "$PROJECT_DIR/scripts/reset-wifi-profiles.sh" "$INSTALL_BIN/reset-wifi-profiles.sh"
install -m 755 "$PROJECT_DIR/scripts/repair-wifi-profile.sh" "$INSTALL_BIN/repair-wifi-profile.sh"

# Remove legacy desktop launchers (tray only)
rm -f "${DESKTOP_HOME}/Desktop/gcs-toggle-ap.desktop"
rm -f "${DESKTOP_HOME}/Desktop/gcs-ap-on.desktop" "${DESKTOP_HOME}/Desktop/gcs-ap-off.desktop"
rm -f "${DESKTOP_HOME}/Desktop/toggle-hotspot.desktop"
rm -f /usr/share/applications/gcs-toggle-ap.desktop
rm -f /usr/share/applications/gcs-ap-settings.desktop
rm -f /usr/local/bin/update-ap-desktop-icon.sh
rm -f /usr/local/bin/remove-ap-desktop.sh

if [[ ! -f "$SUDOERS_FILE" ]] || ! grep -q 'restore-wlan-client.sh' "$SUDOERS_FILE" 2>/dev/null; then
    cat >"$SUDOERS_FILE" <<'EOF'
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/toggle-ap.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/stop-ap-user.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/restore-wlan-client.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/fix-wlan-after-ap.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/cleanup-nm-wifi-duplicates.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/repair-wifi-profile.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/reset-wifi-profiles.sh
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
