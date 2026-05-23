#!/bin/bash
# Install MAV Widget as a systemd user service (autostart on desktop login).

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="mav-widget.service"

if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" ]]; then
    TARGET_USER="${SUDO_USER}"
else
    TARGET_USER="$(whoami)"
fi

TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
TARGET_UID="$(id -u "${TARGET_USER}")"
USER_UNIT_DIR="${TARGET_HOME}/.config/systemd/user"
INSTALLED_UNIT="${USER_UNIT_DIR}/${SERVICE_NAME}"

echo "=== MAV Widget autostart setup ==="
echo "Project: ${PROJECT_DIR}"
echo "User:    ${TARGET_USER}"

chmod +x "${PROJECT_DIR}/scripts/run_widget.sh" "${PROJECT_DIR}/scripts/autostart-gcs.sh"

install -m 755 "${PROJECT_DIR}/scripts/autostart-gcs.sh" /usr/local/bin/autostart-gcs.sh
echo "Installed: /usr/local/bin/autostart-gcs.sh"

mkdir -p "${USER_UNIT_DIR}"
sed "s|__PROJECT_DIR__|${PROJECT_DIR}|g" \
    "${PROJECT_DIR}/systemd/mav-widget.service" > "${INSTALLED_UNIT}"
chown "${TARGET_USER}:${TARGET_USER}" "${INSTALLED_UNIT}"
echo "Installed: ${INSTALLED_UNIT}"

run_user_systemctl() {
    sudo -u "${TARGET_USER}" \
        XDG_RUNTIME_DIR="/run/user/${TARGET_UID}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
        systemctl --user "$@"
}

run_user_systemctl daemon-reload
run_user_systemctl enable "${SERVICE_NAME}"

if run_user_systemctl is-active --quiet "${SERVICE_NAME}"; then
    run_user_systemctl restart "${SERVICE_NAME}"
else
    run_user_systemctl start "${SERVICE_NAME}" || true
fi

echo ""
echo "Status:"
run_user_systemctl status "${SERVICE_NAME}" --no-pager || true

echo ""
echo "Done. Widget will start automatically on desktop login for user ${TARGET_USER}."
echo ""
echo "Useful commands (as ${TARGET_USER}, without sudo):"
echo "  systemctl --user status mav-widget"
echo "  systemctl --user restart mav-widget"
echo "  systemctl --user stop mav-widget"
echo "  journalctl --user -u mav-widget -f"
