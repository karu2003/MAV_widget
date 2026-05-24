#!/bin/bash
# RTSP server on AP address — relays drone/companion video to Wi-Fi clients.
# Requires uap0 with 192.168.54.1 (start after drone-hotspot).

set -euo pipefail

CONF="${GCS_STREAMING_CONF:-/etc/default/gcs-ap-streaming}"
[[ -f "$CONF" ]] && # shellcheck disable=SC1090
source "$CONF"

AP_IP="${AP_IP:-192.168.54.1}"
RTSP_PORT="${RTSP_PORT:-8554}"
RTSP_PATH="${RTSP_PATH:-/stream}"
VIDEO_MODE="${VIDEO_MODE:-udp}"
VIDEO_UDP_PORT="${VIDEO_UDP_PORT:-5600}"
VIDEO_UDP_BIND="${VIDEO_UDP_BIND:-0.0.0.0}"
VIDEO_DEVICE="${VIDEO_DEVICE:-/dev/video0}"
VIDEO_V4L2_SIZE="${VIDEO_V4L2_SIZE:-1280x720}"
VIDEO_V4L2_FPS="${VIDEO_V4L2_FPS:-30}"

RTSP_URL="rtsp://${AP_IP}:${RTSP_PORT}${RTSP_PATH}"

log() { echo "[video-rtsp] $*"; }

if ! command -v ffmpeg >/dev/null; then
    log "ffmpeg not found" >&2
    exit 1
fi

wait_ap() {
    local i
    for i in $(seq 1 45); do
        if ip link show uap0 &>/dev/null && ip -4 addr show dev uap0 2>/dev/null | grep -q "${AP_IP}"; then
            return 0
        fi
        sleep 1
    done
    log "uap0 / ${AP_IP} not ready" >&2
    return 1
}

if pgrep -f '[f]fmpeg.*rtsp.*8554' >/dev/null 2>&1; then
    log "Already running (pid $(pgrep -f '[f]fmpeg.*rtsp' | head -1))"
    exit 0
fi

wait_ap

log "RTSP ${RTSP_URL} (mode=${VIDEO_MODE})"

case "$VIDEO_MODE" in
    udp)
        exec ffmpeg -nostdin -hide_banner -loglevel warning \
            -fflags nobuffer -flags low_delay \
            -i "udp://${VIDEO_UDP_BIND}:${VIDEO_UDP_PORT}?overrun_nonfatal=1&fifo_size=50000000" \
            -c copy \
            -f rtsp -rtsp_flags listen \
            "${RTSP_URL}"
        ;;
    v4l2)
        if [[ ! -e "$VIDEO_DEVICE" ]]; then
            log "No ${VIDEO_DEVICE}" >&2
            exit 1
        fi
        exec ffmpeg -nostdin -hide_banner -loglevel warning \
            -f v4l2 -input_format h264 -video_size "${VIDEO_V4L2_SIZE}" -framerate "${VIDEO_V4L2_FPS}" \
            -i "$VIDEO_DEVICE" \
            -c copy \
            -f rtsp -rtsp_flags listen \
            "${RTSP_URL}"
        ;;
    test)
        exec ffmpeg -nostdin -hide_banner -loglevel warning \
            -f lavfi -i "testsrc=size=640x360:rate=15" \
            -c:v libx264 -preset ultrafast -tune zerolatency -g 15 \
            -f rtsp -rtsp_flags listen \
            "${RTSP_URL}"
        ;;
    *)
        log "Unknown VIDEO_MODE=${VIDEO_MODE} (use udp, v4l2, or test)" >&2
        exit 1
        ;;
esac
