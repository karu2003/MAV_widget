#!/bin/bash
# Install MediaMTX binary to /usr/local/bin/mediamtx (linux arm64).

set -euo pipefail

VERSION="${MEDIAMTX_VERSION:-1.11.3}"
DEST="/usr/local/bin/mediamtx"
ARCH="$(uname -m)"

case "$ARCH" in
    aarch64|arm64) TARBALL="mediamtx_v${VERSION}_linux_arm64v8.tar.gz" ;;
    x86_64|amd64) TARBALL="mediamtx_v${VERSION}_linux_amd64.tar.gz" ;;
    *)
        echo "Unsupported arch: $ARCH" >&2
        exit 1
        ;;
esac

URL="https://github.com/bluenviron/mediamtx/releases/download/v${VERSION}/${TARBALL}"

if [[ -x "$DEST" ]]; then
    echo "[install-mediamtx] Already installed: $("$DEST" -v 2>/dev/null || echo ok)"
    exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "[install-mediamtx] Downloading ${URL}"
curl -fsSL "$URL" -o "${TMP}/${TARBALL}"
tar -xzf "${TMP}/${TARBALL}" -C "$TMP"
install -m 755 "${TMP}/mediamtx" "$DEST"
echo "[install-mediamtx] Installed $DEST"
