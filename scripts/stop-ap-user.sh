#!/bin/bash
# Turn AP off from UI/CLI — set manual-off flag and tear down hostapd/uap0.

set -euo pipefail

/usr/local/bin/gcs-ap-manual-off.sh off
/usr/local/bin/stop-drone-hotspot.sh
systemctl stop drone-hotspot.service 2>/dev/null || true
systemctl reset-failed drone-hotspot.service 2>/dev/null || true
