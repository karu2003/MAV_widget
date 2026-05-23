#!/bin/bash
# Toggle GNOME screen lock and idle suspend (Winmate GCS kiosk mode).

set -euo pipefail

STATE_DIR="${HOME}/.config/mav_widget"
STATE_FILE="${STATE_DIR}/screen-lock-backup.conf"

SCHEMA_SCREENSAVER="org.gnome.desktop.screensaver"
SCHEMA_POWER="org.gnome.settings-daemon.plugins.power"

KEYS=(
    "${SCHEMA_SCREENSAVER}:lock-enabled"
    "${SCHEMA_SCREENSAVER}:idle-activation-enabled"
    "${SCHEMA_SCREENSAVER}:ubuntu-lock-on-suspend"
    "${SCHEMA_POWER}:sleep-inactive-ac-timeout"
    "${SCHEMA_POWER}:sleep-inactive-ac-type"
    "${SCHEMA_POWER}:sleep-inactive-battery-timeout"
    "${SCHEMA_POWER}:sleep-inactive-battery-type"
)

usage() {
    cat <<'EOF'
Usage: toggle-screen-lock.sh [command]

Commands:
  off, disable    Disable screen lock and idle suspend (no login after pause)
  on, enable      Restore previous or default lock/suspend settings
  status          Show current settings
  toggle          Switch between off and on (default)

Examples:
  ./scripts/toggle-screen-lock.sh off
  ./scripts/toggle-screen-lock.sh on
  ./scripts/toggle-screen-lock.sh
EOF
}

setup_session() {
    export DISPLAY="${DISPLAY:-:0}"
    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -S "/run/user/$(id -u)/bus" ]]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
    fi
    XAUTH="$(ls "/run/user/$(id -u)/.mutter-Xwaylandauth."* 2>/dev/null | head -1 || true)"
    if [[ -n "$XAUTH" ]]; then
        export XAUTHORITY="$XAUTH"
    fi
}

gs_get() {
    local schema="${1%%:*}"
    local key="${1#*:}"
    gsettings get "${schema}" "${key}"
}

gs_set() {
    local schema="${1%%:*}"
    local key="${1#*:}"
    local value="$2"
    gsettings set "${schema}" "${key}" "${value}"
}

save_state() {
    mkdir -p "${STATE_DIR}"
    : > "${STATE_FILE}"
    local entry
    for entry in "${KEYS[@]}"; do
        printf '%s=%s\n' "${entry}" "$(gs_get "${entry}")" >> "${STATE_FILE}"
    done
}

apply_kiosk_mode() {
    gs_set "${SCHEMA_SCREENSAVER}:lock-enabled" "false"
    gs_set "${SCHEMA_SCREENSAVER}:idle-activation-enabled" "false"
    gs_set "${SCHEMA_SCREENSAVER}:ubuntu-lock-on-suspend" "false"
    gs_set "${SCHEMA_POWER}:sleep-inactive-ac-timeout" "0"
    gs_set "${SCHEMA_POWER}:sleep-inactive-ac-type" "'nothing'"
    gs_set "${SCHEMA_POWER}:sleep-inactive-battery-timeout" "0"
    gs_set "${SCHEMA_POWER}:sleep-inactive-battery-type" "'nothing'"
}

apply_defaults() {
    gs_set "${SCHEMA_SCREENSAVER}:lock-enabled" "true"
    gs_set "${SCHEMA_SCREENSAVER}:idle-activation-enabled" "false"
    gs_set "${SCHEMA_SCREENSAVER}:ubuntu-lock-on-suspend" "true"
    gs_set "${SCHEMA_POWER}:sleep-inactive-ac-timeout" "1800"
    gs_set "${SCHEMA_POWER}:sleep-inactive-ac-type" "'suspend'"
    gs_set "${SCHEMA_POWER}:sleep-inactive-battery-timeout" "900"
    gs_set "${SCHEMA_POWER}:sleep-inactive-battery-type" "'suspend'"
}

restore_state() {
    if [[ ! -f "${STATE_FILE}" ]]; then
        apply_defaults
        return
    fi

    local line schema key value
    while IFS='=' read -r line; do
        [[ -z "${line}" ]] && continue
        schema="${line%%:*}"
        key="${line#*:}"
        key="${key%%=*}"
        value="${line#*=}"
        gsettings set "${schema}" "${key}" "${value}"
    done < "${STATE_FILE}"
}

show_status() {
    local entry
    echo "Screen lock / idle suspend status:"
    for entry in "${KEYS[@]}"; do
        printf '  %-55s %s\n' "${entry}" "$(gs_get "${entry}")"
    done
    if [[ -f "${STATE_FILE}" ]]; then
        echo ""
        echo "Backup: ${STATE_FILE}"
    fi
    if [[ "$(gs_get "${SCHEMA_SCREENSAVER}:lock-enabled")" == "false" ]]; then
        echo ""
        echo "Mode: OFF (kiosk — no login after idle pause)"
    else
        echo ""
        echo "Mode: ON (screen lock / suspend enabled)"
    fi
}

disable_lock() {
    if [[ "$(gs_get "${SCHEMA_SCREENSAVER}:lock-enabled")" == "true" ]]; then
        save_state
    fi
    apply_kiosk_mode
    echo "Screen lock and idle suspend disabled."
    echo "GCS will not ask for a password after a long pause."
}

enable_lock() {
    restore_state
    echo "Screen lock and idle suspend restored."
}

toggle_lock() {
    if [[ "$(gs_get "${SCHEMA_SCREENSAVER}:lock-enabled")" == "false" ]]; then
        enable_lock
    else
        disable_lock
    fi
}

main() {
    setup_session

    if ! command -v gsettings >/dev/null 2>&1; then
        echo "Error: gsettings not found (GNOME session required)." >&2
        exit 1
    fi

    local cmd="${1:-toggle}"
    case "${cmd}" in
        off|disable)
            disable_lock
            ;;
        on|enable)
            enable_lock
            ;;
        status)
            show_status
            ;;
        toggle)
            toggle_lock
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            echo "Unknown command: ${cmd}" >&2
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"
