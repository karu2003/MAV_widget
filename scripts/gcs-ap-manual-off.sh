#!/bin/bash
# Mark AP as manually off/on (prevents auto-start until user toggles on).

set -euo pipefail

FLAG="/var/lib/gcs-ap/manual-off"

case "${1:-}" in
    off)
        mkdir -p /var/lib/gcs-ap
        touch "$FLAG"
        echo "[gcs-ap] Manual OFF — AP will not auto-start"
        ;;
    on)
        rm -f "$FLAG"
        echo "[gcs-ap] Manual OFF cleared — AP may start"
        ;;
    *)
        echo "Usage: $0 off|on" >&2
        exit 1
        ;;
esac
