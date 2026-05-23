#!/bin/bash
# Wait until MAVProxy forwards telemetry (optional; widget reconnects on its own).

set -euo pipefail

WIDGET_PORT="${1:-14552}"
MAX_WAIT_S="${2:-30}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/wait_gcs_ready.sh" heartbeat "$WIDGET_PORT" "$MAX_WAIT_S"
