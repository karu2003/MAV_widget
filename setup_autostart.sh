#!/bin/bash
# Install MAV Widget as a systemd user service (autostart on desktop login).

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="mav-widget.service"
USER_UNIT_DIR="${HOME}/.config/systemd/user"
INSTALLED_UNIT="${USER_UNIT_DIR}/${SERVICE_NAME}"

echo "=== MAV Widget autostart setup ==="
echo "Project: ${PROJECT_DIR}"

chmod +x "${PROJECT_DIR}/scripts/run_widget.sh"

mkdir -p "${USER_UNIT_DIR}"

sed "s|__PROJECT_DIR__|${PROJECT_DIR}|g" \
    "${PROJECT_DIR}/systemd/mav-widget.service" > "${INSTALLED_UNIT}"

echo "Installed: ${INSTALLED_UNIT}"

systemctl --user daemon-reload
systemctl --user enable "${SERVICE_NAME}"

if systemctl --user is-active --quiet "${SERVICE_NAME}"; then
    systemctl --user restart "${SERVICE_NAME}"
else
    systemctl --user start "${SERVICE_NAME}"
fi

echo ""
echo "Status:"
systemctl --user status "${SERVICE_NAME}" --no-pager || true

echo ""
echo "Done. Widget will start automatically on desktop login."
echo ""
echo "Useful commands:"
echo "  systemctl --user status mav-widget"
echo "  systemctl --user restart mav-widget"
echo "  systemctl --user stop mav-widget"
echo "  journalctl --user -u mav-widget -f"
