#!/bin/bash
# View MAV GCS logs (works when journalctl --user has no journal files).

set -euo pipefail

LOG_DIR="${HOME}/.local/state/mav-gcs"
FOLLOW=false
LINES=50

usage() {
    echo "Usage: $0 [-f] [-n lines] [mavproxy|widget|all]" >&2
    exit 2
}

while getopts "fn:h" opt; do
    case "$opt" in
        f) FOLLOW=true ;;
        n) LINES="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

TARGET="${1:-all}"

show_file() {
    local file="$1"
  local label="$2"
    if [[ ! -f "$file" ]]; then
        echo "=== $label: (no log yet) $file ==="
        return
    fi
    echo "=== $label: $file ==="
    if $FOLLOW; then
        tail -n "$LINES" -f "$file"
    else
        tail -n "$LINES" "$file"
    fi
}

case "$TARGET" in
    mavproxy|mavproxy-gcs)
        show_file "${LOG_DIR}/mavproxy-gcs.log" "mavproxy-gcs"
        ;;
    widget|mav-widget)
        show_file "${LOG_DIR}/mav-widget.log" "mav-widget"
        ;;
    all)
        show_file "${LOG_DIR}/mavproxy-gcs.log" "mavproxy-gcs"
        echo ""
        show_file "${LOG_DIR}/mav-widget.log" "mav-widget"
        echo ""
        echo "Tip: systemctl --user status mavproxy-gcs mav-widget"
        echo "     journalctl -b --no-pager | grep -E 'mav-widget|mavproxy|run_widget'"
        ;;
    *)
        usage
        ;;
esac
