#!/bin/bash
# Install drone WiFi AP boot service and fix hostapd/dnsmasq startup order.
# Run as root: sudo ./setup_wifi_ap.sh

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_BIN="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
SUDOERS_FILE="/etc/sudoers.d/mav-widget-hotspot"

if [[ -n "${SUDO_USER:-}" ]]; then
    DESKTOP_USER="${SUDO_USER}"
else
    DESKTOP_USER="$(whoami)"
fi
DESKTOP_HOME="$(getent passwd "${DESKTOP_USER}" | cut -d: -f6)"

echo "=== Drone WiFi AP setup ==="
echo "Project: $PROJECT_DIR"

install -m 755 "$PROJECT_DIR/scripts/start-drone-hotspot.sh" "$INSTALL_BIN/start-drone-hotspot.sh"
install -m 755 "$PROJECT_DIR/scripts/stop-drone-hotspot.sh" "$INSTALL_BIN/stop-drone-hotspot.sh"
install -m 755 "$PROJECT_DIR/scripts/setup-nat.sh" "$INSTALL_BIN/setup-nat.sh"
install -m 755 "$PROJECT_DIR/scripts/check-nat.sh" "$INSTALL_BIN/check-nat.sh"
install -m 755 "$PROJECT_DIR/scripts/setup_network.sh" "$INSTALL_BIN/setup-network.sh"
install -m 755 "$PROJECT_DIR/scripts/ensure_network.sh" "$INSTALL_BIN/ensure-network.sh"
install -m 755 "$PROJECT_DIR/scripts/check-network.sh" "$INSTALL_BIN/check-network.sh"
install -m 755 "$PROJECT_DIR/scripts/autostart-gcs.sh" "$INSTALL_BIN/autostart-gcs.sh"
install -m 755 "$PROJECT_DIR/scripts/toggle-ap.sh" "$INSTALL_BIN/toggle-ap.sh"
install -m 755 "$PROJECT_DIR/scripts/gcs-ap-manual-off.sh" "$INSTALL_BIN/gcs-ap-manual-off.sh"
install -m 755 "$PROJECT_DIR/scripts/stop-ap-user.sh" "$INSTALL_BIN/stop-ap-user.sh"
install -m 755 "$PROJECT_DIR/scripts/install-ap-tray.sh" "$INSTALL_BIN/install-ap-tray.sh"
ICON_DIR="/usr/local/share/icons/hicolor/scalable/apps"
PNG_DIR="/usr/local/share/icons/hicolor/48x48/apps"
mkdir -p "$ICON_DIR" "$PNG_DIR"
install -m 644 "$PROJECT_DIR/config/icons/gcs-ap-on.svg" "${ICON_DIR}/gcs-ap-on.svg"
install -m 644 "$PROJECT_DIR/config/icons/gcs-ap-off.svg" "${ICON_DIR}/gcs-ap-off.svg"
if command -v ffmpeg >/dev/null; then
    ffmpeg -y -loglevel error -i "${ICON_DIR}/gcs-ap-on.svg" -vf scale=48:48 "${PNG_DIR}/gcs-ap-on.png" 2>/dev/null || true
    ffmpeg -y -loglevel error -i "${ICON_DIR}/gcs-ap-off.svg" -vf scale=48:48 "${PNG_DIR}/gcs-ap-off.png" 2>/dev/null || true
fi
install -m 644 "$PROJECT_DIR/config/icons/hicolor-index.theme" /usr/local/share/icons/hicolor/index.theme
if command -v gtk-update-icon-cache >/dev/null; then
    gtk-update-icon-cache -f /usr/local/share/icons/hicolor 2>/dev/null || true
fi
install -m 755 "$PROJECT_DIR/scripts/start-video-rtsp.sh" "$INSTALL_BIN/start-video-rtsp.sh"
install -m 755 "$PROJECT_DIR/scripts/wlan-concurrent.sh" "$INSTALL_BIN/wlan-concurrent.sh"
install -m 755 "$PROJECT_DIR/scripts/restore-wlan-client.sh" "$INSTALL_BIN/restore-wlan-client.sh"
install -m 755 "$PROJECT_DIR/scripts/wlan-concurrent-keepalive.sh" "$INSTALL_BIN/wlan-concurrent-keepalive.sh"
install -m 755 "$PROJECT_DIR/scripts/reset-wifi-profiles.sh" "$INSTALL_BIN/reset-wifi-profiles.sh"
install -m 755 "$PROJECT_DIR/scripts/fix-wlan-after-ap.sh" "$INSTALL_BIN/fix-wlan-after-ap.sh"
install -m 755 "$PROJECT_DIR/scripts/restart-ap-streaming.sh" "$INSTALL_BIN/restart-ap-streaming.sh"
install -m 755 "$PROJECT_DIR/scripts/check-ap-stream.sh" "$INSTALL_BIN/check-ap-stream.sh"
install -m 755 "$PROJECT_DIR/scripts/check-gcs-link.sh" "$INSTALL_BIN/check-gcs-link.sh"
install -m 755 "$PROJECT_DIR/scripts/configure-wlan-client.sh" "$INSTALL_BIN/configure-wlan-client.sh"
install -m 755 "$PROJECT_DIR/scripts/install-mediamtx.sh" "$INSTALL_BIN/install-mediamtx.sh"
install -m 755 "$PROJECT_DIR/scripts/video-udp-relay.py" "$INSTALL_BIN/video-udp-relay.py"
install -m 644 "$PROJECT_DIR/systemd/gcs-video-udp-relay.service" "$SYSTEMD_DIR/gcs-video-udp-relay.service"
install -m 644 "$PROJECT_DIR/config/gcs-ap-streaming.conf" /etc/default/gcs-ap-streaming.template
if [[ ! -f /etc/default/gcs-ap-streaming ]]; then
    install -m 644 "$PROJECT_DIR/config/gcs-ap-streaming.conf" /etc/default/gcs-ap-streaming
else
    echo "Keeping /etc/default/gcs-ap-streaming (set GCS_WLAN_CONNECTION for wlan0 client)"
fi
install -m 644 "$PROJECT_DIR/config/mediamtx-gcs.yml" /etc/mediamtx-gcs.yml.template
"$INSTALL_BIN/install-mediamtx.sh" || echo "WARN: MediaMTX install skipped (no network?) — run: sudo install-mediamtx.sh"
install -m 755 "$PROJECT_DIR/scripts/gcs-ap-tray.py" "$INSTALL_BIN/gcs-ap-tray.py"
# Tray only — remove any legacy desktop / menu launchers
rm -f "${DESKTOP_HOME}/Desktop/gcs-toggle-ap.desktop"
rm -f "${DESKTOP_HOME}/Desktop/gcs-ap-on.desktop" "${DESKTOP_HOME}/Desktop/gcs-ap-off.desktop"
rm -f "${DESKTOP_HOME}/Desktop/toggle-hotspot.desktop"
rm -f /usr/share/applications/gcs-toggle-ap.desktop
rm -f /usr/share/applications/gcs-ap-settings.desktop
rm -f /usr/local/bin/update-ap-desktop-icon.sh
USER_UNIT_DIR="${DESKTOP_HOME}/.config/systemd/user"
mkdir -p "${USER_UNIT_DIR}"
cp "$PROJECT_DIR/systemd/gcs-ap-tray.service" "${USER_UNIT_DIR}/"
chown "${DESKTOP_USER}:${DESKTOP_USER}" "${USER_UNIT_DIR}/gcs-ap-tray.service"
rm -f "${USER_UNIT_DIR}/gcs-ap-icon-refresh.service" "${USER_UNIT_DIR}/gcs-ap-icon-refresh.timer"
DESKTOP_UID="$(id -u "${DESKTOP_USER}")"
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
        systemctl --user daemon-reload 2>/dev/null || true
    sudo -u "${DESKTOP_USER}" \
        XDG_RUNTIME_DIR="/run/user/${DESKTOP_UID}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${DESKTOP_UID}/bus" \
        systemctl --user enable --now gcs-ap-tray.service 2>/dev/null || true
fi
echo "AP control: gcs-ap-tray.service (top panel icon only)"

mkdir -p /var/lib/gcs-ap
touch /var/lib/gcs-ap/manual-off
"$INSTALL_BIN/ensure-hostapd-concurrent.sh" 2>/dev/null || true

# Passwordless sudo (before long network setup — do not interrupt before this)
cat > "$SUDOERS_FILE" <<'EOF'
# MAV Widget — GCS AP toggle (tray + CLI)
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/toggle-ap.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/stop-ap-user.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/start-drone-hotspot.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/stop-drone-hotspot.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/start-universal-hotspot.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/stop-universal-hotspot.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/autostart-gcs.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/setup-nat.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/check-nat.sh
ubuntu ALL=(root) NOPASSWD: /usr/sbin/iptables
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/toggle-hotspot.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/gcs-ap-manual-off.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/restart-ap-streaming.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/restore-wlan-client.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/reset-wifi-profiles.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/fix-wlan-after-ap.sh
ubuntu ALL=(root) NOPASSWD: /usr/bin/systemctl start gcs-video-rtsp.service
ubuntu ALL=(root) NOPASSWD: /usr/bin/systemctl stop gcs-video-rtsp.service
ubuntu ALL=(root) NOPASSWD: /usr/bin/systemctl restart gcs-video-rtsp.service
ubuntu ALL=(root) NOPASSWD: /usr/bin/systemctl start drone-hotspot.service
ubuntu ALL=(root) NOPASSWD: /usr/bin/systemctl stop drone-hotspot.service
ubuntu ALL=(root) NOPASSWD: /usr/bin/systemctl restart drone-hotspot.service
ubuntu ALL=(root) NOPASSWD: /usr/bin/systemctl reset-failed drone-hotspot.service
ubuntu ALL=(root) NOPASSWD: /usr/sbin/iw
ubuntu ALL=(root) NOPASSWD: /usr/sbin/ip
ubuntu ALL=(root) NOPASSWD: /usr/sbin/sysctl
ubuntu ALL=(root) NOPASSWD: /usr/bin/systemctl start hostapd
ubuntu ALL=(root) NOPASSWD: /usr/bin/systemctl stop hostapd
ubuntu ALL=(root) NOPASSWD: /usr/bin/systemctl start dnsmasq
ubuntu ALL=(root) NOPASSWD: /usr/bin/systemctl stop dnsmasq
ubuntu ALL=(root) NOPASSWD: /usr/bin/killall -9 hostapd
ubuntu ALL=(root) NOPASSWD: /usr/bin/killall -9 dnsmasq
ubuntu ALL=(root) NOPASSWD: /usr/bin/killall -9 mavproxy
ubuntu ALL=(root) NOPASSWD: /usr/bin/killall -9 python3
EOF
chmod 440 "$SUDOERS_FILE"
echo "sudoers: $SUDOERS_FILE (toggle-ap.sh = passwordless AP on/off from tray)"

mkdir -p /etc/dnsmasq.d
install -m 644 "$PROJECT_DIR/config/dnsmasq-drone-hotspot.conf" /etc/dnsmasq.d/drone-hotspot.conf

# Disable NM background scans (off-channel scans disrupt single-radio STA+AP).
mkdir -p /etc/NetworkManager/conf.d
install -m 644 "$PROJECT_DIR/config/gcs-concurrent-wifi.conf" \
    /etc/NetworkManager/conf.d/gcs-concurrent-wifi.conf

MAV_WIDGET_DIR="$PROJECT_DIR" "$PROJECT_DIR/scripts/setup_network.sh"

sed "s|__PROJECT_DIR__|$PROJECT_DIR|g" \
    "$PROJECT_DIR/systemd/drone-hotspot.service" > "$SYSTEMD_DIR/drone-hotspot.service"
install -m 644 "$PROJECT_DIR/systemd/gcs-video-rtsp.service" "$SYSTEMD_DIR/gcs-video-rtsp.service"

install -m 644 "$PROJECT_DIR/systemd/gcs-ap-default-off.service" "$SYSTEMD_DIR/gcs-ap-default-off.service"
install -m 644 "$PROJECT_DIR/systemd/gcs-wlan-keepalive.service" "$SYSTEMD_DIR/gcs-wlan-keepalive.service"
install -m 644 "$PROJECT_DIR/systemd/gcs-wlan-keepalive.timer" "$SYSTEMD_DIR/gcs-wlan-keepalive.timer"
install -m 755 "$PROJECT_DIR/scripts/cleanup-nm-wifi-duplicates.sh" "$INSTALL_BIN/cleanup-nm-wifi-duplicates.sh"

# hostapd/dnsmasq must not start before uap0 exists
systemctl disable hostapd dnsmasq 2>/dev/null || true

systemctl daemon-reload
systemctl enable gcs-ap-default-off.service \
    gcs-video-udp-relay.service gcs-video-rtsp.service gcs-wlan-keepalive.timer
systemctl disable drone-hotspot.service 2>/dev/null || true
systemctl start gcs-ap-default-off.service 2>/dev/null || true
systemctl stop drone-hotspot.service 2>/dev/null || true
"$INSTALL_BIN/stop-drone-hotspot.sh" --no-restore 2>/dev/null || true
systemctl restart gcs-video-udp-relay.service gcs-video-rtsp.service 2>/dev/null || true
"$INSTALL_BIN/setup-nat.sh"

# Fix broken GNOME autostart (was executing .desktop file as shell script)
# MAVProxy is started by mavproxy-gcs.service — keep desktop entry hidden.
AUTOSTART="/home/ubuntu/.config/autostart/toggle-hotspot.desktop"
if [[ -f "$AUTOSTART" ]]; then
    cat > "$AUTOSTART" <<'EOF'
[Desktop Entry]
Type=Application
Exec=/usr/local/bin/autostart-gcs.sh
Hidden=true
NoDisplay=true
X-GNOME-Autostart-enabled=false
Name=GCS MAVProxy (legacy)
Comment=Use mavproxy-gcs.service — run ./setup_autostart.sh
EOF
    chown ubuntu:ubuntu "$AUTOSTART"
    echo "Fixed autostart: $AUTOSTART"
fi

echo ""
echo "Status:"
systemctl status drone-hotspot.service --no-pager || true
echo ""
systemctl status hostapd dnsmasq --no-pager || true
echo ""
ip -br addr show wlan0 uap0 2>/dev/null || true
echo ""
echo "Done."
echo "  AP SSID: see /etc/hostapd/drone-hotspot.conf  IP: 192.168.54.1"
echo "  MAVLink AP: udpbcast :14550  |  RTSP: rtsp://192.168.54.1:8554/stream"
echo "  check-ap-stream.sh"
echo "  Client WiFi: wlan0 (NetworkManager)"
echo ""
echo "Commands:"
echo "  Top panel tray icon  # right-click: on/off, settings"
echo "  toggle-ap.sh         # terminal"
echo "  systemctl --user status gcs-ap-tray"
