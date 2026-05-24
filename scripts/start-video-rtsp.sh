#!/bin/bash
# MediaMTX (publisher) + ffmpeg RTP/H264 (127.0.0.1:5601) -> RTSP on AP.

set -euo pipefail

CONF="${GCS_STREAMING_CONF:-/etc/default/gcs-ap-streaming}"
[[ -f "$CONF" ]] && # shellcheck disable=SC1090
source "$CONF"

AP_IP="${AP_IP:-192.168.54.1}"
RTSP_PORT="${RTSP_PORT:-8554}"
RTSP_PATH="${RTSP_PATH:-/stream}"
VIDEO_MODE="${VIDEO_MODE:-udp}"
VIDEO_FWD_PORT="${VIDEO_FWD_PORT:-5601}"

MEDIAMTX_BIN="${MEDIAMTX_BIN:-/usr/local/bin/mediamtx}"
MEDIAMTX_TEMPLATE="${MEDIAMTX_TEMPLATE:-/etc/mediamtx-gcs.yml.template}"
MEDIAMTX_RUNTIME="${MEDIAMTX_RUNTIME:-/run/mediamtx-gcs.yml}"
RTP_SDP="${RTP_SDP:-/run/gcs-video-rtp.sdp}"

RTSP_PUBLISH="rtsp://${AP_IP}:${RTSP_PORT}${RTSP_PATH}"

log() { echo "[video-rtsp] $*"; }

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

ensure_udp_relay() {
    [[ "$VIDEO_MODE" == "udp" ]] || return 0
    if systemctl is-active --quiet gcs-video-udp-relay.service 2>/dev/null \
        || pgrep -f '[v]ideo-udp-relay.py' >/dev/null; then
        return 0
    fi
    log "Starting gcs-video-udp-relay..."
    systemctl start gcs-video-udp-relay.service 2>/dev/null || true
    sleep 1
}

wait_mediamtx() {
    local i
    for i in $(seq 1 30); do
        if ss -ltn 2>/dev/null | grep -q "${AP_IP}:${RTSP_PORT}"; then
            return 0
        fi
        sleep 1
    done
    log "MediaMTX not listening on ${AP_IP}:${RTSP_PORT}" >&2
    return 1
}

render_mediamtx_config() {
    sed \
        -e "s/__AP_IP__/${AP_IP}/g" \
        -e "s/__RTSP_PORT__/${RTSP_PORT}/g" \
        "$1" >"$2"
}

write_rtp_sdp() {
    cat >"$RTP_SDP" <<EOF
v=0
o=- 0 0 IN IP4 127.0.0.1
s=GCS drone video
c=IN IP4 127.0.0.1
t=0 0
m=video ${VIDEO_FWD_PORT} RTP/AVP 96
a=rtpmap:96 H264/90000
a=fmtp:96 packetization-mode=1
EOF
}

start_mediamtx() {
    render_mediamtx_config "$MEDIAMTX_TEMPLATE" "$MEDIAMTX_RUNTIME"
    if pgrep -f '[m]ediamtx /run/mediamtx-gcs' >/dev/null 2>&1; then
        log "MediaMTX already running"
        return 0
    fi
    log "MediaMTX ${RTSP_PUBLISH} (publisher)"
    "$MEDIAMTX_BIN" "$MEDIAMTX_RUNTIME" &
    sleep 1
}

publish_rtp() {
    write_rtp_sdp
    ffmpeg -nostdin -hide_banner -loglevel warning \
        -protocol_whitelist file,udp,rtp \
        -fflags nobuffer -flags low_delay \
        -i "$RTP_SDP" \
        -c copy \
        -f rtsp -rtsp_transport tcp \
        "$RTSP_PUBLISH"
}

publish_test() {
    ffmpeg -nostdin -hide_banner -loglevel warning \
        -f lavfi -i "testsrc=size=640x360:rate=15" \
        -c:v libx264 -preset ultrafast -tune zerolatency -g 15 \
        -f rtsp -rtsp_transport tcp \
        "$RTSP_PUBLISH"
}

publisher_loop() {
    while true; do
        case "$VIDEO_MODE" in
            udp)
                publish_rtp || log "RTP publish ended — retrying"
                ;;
            test)
                publish_test || log "test publish ended"
                ;;
            *)
                log "Unknown VIDEO_MODE=${VIDEO_MODE}" >&2
                exit 1
                ;;
        esac
        sleep 2
    done
}

cleanup() {
    pkill -f '[m]ediamtx /run/mediamtx-gcs' 2>/dev/null || true
    pkill -f '[f]fmpeg.*rtsp.*8554' 2>/dev/null || true
}
trap cleanup EXIT INT TERM

wait_ap
ensure_udp_relay
start_mediamtx
wait_mediamtx || true
log "ffmpeg RTP :${VIDEO_FWD_PORT} -> ${RTSP_PUBLISH}"
publisher_loop
