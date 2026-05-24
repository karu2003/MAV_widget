#!/bin/bash
# Remove NetworkManager duplicate Wi‑Fi profiles (e.g. "CuCU" from NM auto-rename).

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

removed=0
while IFS=: read -r name type; do
    [[ "$type" != "802-11-wireless" ]] && continue
    [[ "$name" =~ [[:space:]][0-9]+$ ]] || continue
    echo "[cleanup-nm] Removing duplicate profile: ${name}"
    nmcli connection delete "$name" 2>/dev/null && removed=$((removed + 1)) || true
done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null)

echo "[cleanup-nm] Removed ${removed} duplicate profile(s)"
echo "[cleanup-nm] Use original names only (nmcli connection show)"
