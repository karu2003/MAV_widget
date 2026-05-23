#!/bin/bash
# Launch MAV widget on the local display (Winmate / GNOME Wayland).

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

export DISPLAY="${DISPLAY:-:0}"

XAUTH="$(ls "/run/user/$(id -u)/.mutter-Xwaylandauth."* 2>/dev/null | head -1 || true)"
if [[ -n "$XAUTH" ]]; then
    export XAUTHORITY="$XAUTH"
fi

exec python3 "$PROJECT_DIR/widget.py" --geometry +20+20 "$@"
