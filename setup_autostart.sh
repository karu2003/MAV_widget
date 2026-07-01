#!/bin/bash
# Install MAVProxy + widget as systemd user services (autostart on desktop login).

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAVPROXY_SERVICE="mavproxy-gcs.service"
WIDGET_SERVICE="mav-widget.service"
FANOUT_SERVICE="mav-ap-fanout.service"

if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" ]]; then
    TARGET_USER="${SUDO_USER}"
else
    TARGET_USER="$(whoami)"
fi

TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
TARGET_UID="$(id -u "${TARGET_USER}")"
USER_UNIT_DIR="${TARGET_HOME}/.config/systemd/user"
LOG_DIR="${TARGET_HOME}/.local/state/mav-gcs"

echo "=== MAV GCS autostart setup ==="
echo "Project: ${PROJECT_DIR}"
echo "User:    ${TARGET_USER}"

chmod +x \
    "${PROJECT_DIR}/scripts/run_widget.sh" \
    "${PROJECT_DIR}/scripts/autostart-gcs.sh" \
    "${PROJECT_DIR}/scripts/start_mavproxy.sh" \
    "${PROJECT_DIR}/scripts/mav-ap-fanout.py" \
    "${PROJECT_DIR}/scripts/wait_gcs_ready.sh" \
    "${PROJECT_DIR}/scripts/wait_mavproxy_link.sh" \
    "${PROJECT_DIR}/scripts/logs.sh" \
    "${PROJECT_DIR}/scripts/check-nat.sh" \
    "${PROJECT_DIR}/scripts/setup-nat.sh"

mkdir -p "${LOG_DIR}"
chown "${TARGET_USER}:${TARGET_USER}" "${LOG_DIR}"
echo "Log dir: ${LOG_DIR}"

install -m 755 "${PROJECT_DIR}/scripts/autostart-gcs.sh" /usr/local/bin/autostart-gcs.sh
install -m 755 "${PROJECT_DIR}/scripts/start_mavproxy.sh" /usr/local/bin/start_mavproxy.sh
install -m 755 "${PROJECT_DIR}/scripts/wait_gcs_ready.sh" /usr/local/bin/wait_gcs_ready.sh
install -m 755 "${PROJECT_DIR}/scripts/logs.sh" /usr/local/bin/mav-gcs-logs.sh
install -m 755 "${PROJECT_DIR}/scripts/check-nat.sh" /usr/local/bin/check-nat.sh
install -m 755 "${PROJECT_DIR}/scripts/setup-nat.sh" /usr/local/bin/setup-nat.sh
echo "Installed: /usr/local/bin/{autostart-gcs,start_mavproxy,wait_gcs_ready,mav-gcs-logs,check-nat,setup-nat}.sh"

if [[ "$(id -u)" -eq 0 ]]; then
    echo ""
    echo "Applying NAT (wlan0/eth1 -> uap0/eth0)..."
    "${PROJECT_DIR}/scripts/setup-nat.sh" || echo "WARN: setup-nat failed"
fi

mkdir -p "${USER_UNIT_DIR}"
for svc in "${MAVPROXY_SERVICE}" "${WIDGET_SERVICE}" "${FANOUT_SERVICE}"; do
    unit="${svc%.service}"
    sed -e "s|__PROJECT_DIR__|${PROJECT_DIR}|g" -e "s|__LOG_DIR__|${LOG_DIR}|g" \
        "${PROJECT_DIR}/systemd/${unit}.service" > "${USER_UNIT_DIR}/${svc}"
    chown "${TARGET_USER}:${TARGET_USER}" "${USER_UNIT_DIR}/${svc}"
    echo "Installed: ${USER_UNIT_DIR}/${svc}"
done

# Avoid double MAVProxy start from GNOME autostart (systemd handles boot order).
DESKTOP="${TARGET_HOME}/.config/autostart/toggle-hotspot.desktop"
if [[ -f "$DESKTOP" ]]; then
    if grep -q '^Hidden=' "$DESKTOP"; then
        sed -i 's/^Hidden=.*/Hidden=true/' "$DESKTOP"
    else
        echo "Hidden=true" >> "$DESKTOP"
    fi
    chown "${TARGET_USER}:${TARGET_USER}" "$DESKTOP"
    echo "Disabled duplicate GNOME autostart: $DESKTOP"
fi

run_user_systemctl() {
    sudo -u "${TARGET_USER}" \
        XDG_RUNTIME_DIR="/run/user/${TARGET_UID}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
        systemctl --user "$@"
}

run_user_systemctl daemon-reload
run_user_systemctl enable "${MAVPROXY_SERVICE}" "${WIDGET_SERVICE}" "${FANOUT_SERVICE}"
run_user_systemctl restart "${MAVPROXY_SERVICE}" "${WIDGET_SERVICE}" "${FANOUT_SERVICE}" || true

echo ""
echo "Status:"
run_user_systemctl status "${MAVPROXY_SERVICE}" --no-pager || true
echo ""
run_user_systemctl status "${WIDGET_SERVICE}" --no-pager || true

echo ""
echo "Done. On login: mavproxy-gcs and mav-widget start in parallel."
echo ""
echo "Useful commands (as ${TARGET_USER}, without sudo):"
echo "  systemctl --user status mavproxy-gcs mav-widget"
echo "  mav-gcs-logs.sh -f              # log files (~/.local/state/mav-gcs/)"
echo "  check-nat.sh                    # NAT: wlan0+eth1 -> AP + 192.168.53.x"
echo "  sudo setup-nat.sh               # re-apply NAT rules"
