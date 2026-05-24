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
install -m 644 "$PROJECT_DIR/config/gcs-toggle-ap.desktop" /usr/share/applications/gcs-toggle-ap.desktop
mkdir -p "${DESKTOP_HOME}/Desktop"
install -m 755 "$PROJECT_DIR/config/gcs-toggle-ap.desktop" "${DESKTOP_HOME}/Desktop/gcs-toggle-ap.desktop"
chown "${DESKTOP_USER}:${DESKTOP_USER}" "${DESKTOP_HOME}/Desktop/gcs-toggle-ap.desktop"
# GNOME treats ~/Desktop/*.desktop as untrusted until executable + trusted metadata.
if command -v gio >/dev/null 2>&1; then
    sudo -u "${DESKTOP_USER}" gio set "${DESKTOP_HOME}/Desktop/gcs-toggle-ap.desktop" metadata::trusted true 2>/dev/null || true
fi
echo "GNOME launcher: /usr/share/applications/gcs-toggle-ap.desktop"
echo "Desktop icon:     ${DESKTOP_HOME}/Desktop/gcs-toggle-ap.desktop"

mkdir -p /etc/dnsmasq.d
install -m 644 "$PROJECT_DIR/config/dnsmasq-drone-hotspot.conf" /etc/dnsmasq.d/drone-hotspot.conf

MAV_WIDGET_DIR="$PROJECT_DIR" "$PROJECT_DIR/scripts/setup_network.sh"

sed "s|__PROJECT_DIR__|$PROJECT_DIR|g" \
    "$PROJECT_DIR/systemd/drone-hotspot.service" > "$SYSTEMD_DIR/drone-hotspot.service"

# hostapd/dnsmasq must not start before uap0 exists
systemctl disable hostapd dnsmasq 2>/dev/null || true

systemctl daemon-reload
systemctl enable drone-hotspot.service
systemctl restart drone-hotspot.service
"$INSTALL_BIN/setup-nat.sh"

# Passwordless sudo for GCS scripts (ubuntu user)
cat > "$SUDOERS_FILE" <<'EOF'
# MAV Widget — hotspot and MAVProxy autostart
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/start-drone-hotspot.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/stop-drone-hotspot.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/start-universal-hotspot.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/stop-universal-hotspot.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/autostart-gcs.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/setup-nat.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/check-nat.sh
ubuntu ALL=(root) NOPASSWD: /usr/sbin/iptables
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/toggle-hotspot.sh
ubuntu ALL=(root) NOPASSWD: /usr/local/bin/toggle-ap.sh
ubuntu ALL=(root) NOPASSWD: /usr/bin/systemctl start drone-hotspot.service
ubuntu ALL=(root) NOPASSWD: /usr/bin/systemctl stop drone-hotspot.service
ubuntu ALL=(root) NOPASSWD: /usr/bin/systemctl restart drone-hotspot.service
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
echo "  AP SSID: MantaAP  IP: 192.168.54.1"
echo "  Client WiFi: wlan0 (NetworkManager)"
echo ""
echo "Commands:"
echo "  toggle-ap.sh              # GNOME: app menu / desktop icon"
echo "  systemctl status drone-hotspot"
echo "  systemctl restart drone-hotspot"
echo "  journalctl -u drone-hotspot -u hostapd -u dnsmasq -b"
