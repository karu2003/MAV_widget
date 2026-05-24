#!/usr/bin/env python3
"""Tap H.264 UDP :5600 on eth0 and copy to localhost for ffmpeg (QGC keeps :5600)."""

from __future__ import annotations

import os
import socket
import struct
import sys

ETH_HLEN = 14
IP_PROTO_UDP = 17
DEFAULT_IFACE = "eth0"
DEFAULT_DPORT = 5600
DEFAULT_FWD = ("127.0.0.1", 5601)


def udp_payload_from_frame(data: bytes, dport: int) -> bytes | None:
    if len(data) < ETH_HLEN + 20:
        return None
    if struct.unpack("!H", data[12:14])[0] != 0x0800:
        return None
    ip = data[ETH_HLEN:]
    ihl = (ip[0] & 0x0F) * 4
    if len(ip) < ihl + 8 or ip[9] != IP_PROTO_UDP:
        return None
    udp = ip[ihl:]
    _, dst_port, length, _ = struct.unpack("!HHHH", udp[:8])
    if dst_port != dport:
        return None
    payload_len = length - 8
    if payload_len <= 0 or len(udp) < 8 + payload_len:
        return None
    return udp[8 : 8 + payload_len]


def main() -> int:
    iface = os.environ.get("VIDEO_IFACE", DEFAULT_IFACE)
    dport = int(os.environ.get("VIDEO_UDP_PORT", DEFAULT_DPORT))
    fwd_host = os.environ.get("VIDEO_FWD_HOST", DEFAULT_FWD[0])
    fwd_port = int(os.environ.get("VIDEO_FWD_PORT", DEFAULT_FWD[1]))
    fwd = (fwd_host, fwd_port)

    out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    raw = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
    try:
        raw.bind((iface, 0))
    except OSError as exc:
        print(f"[video-udp-relay] bind {iface}: {exc}", file=sys.stderr)
        return 1

    print(f"[video-udp-relay] {iface} UDP :{dport} -> {fwd[0]}:{fwd[1]}", flush=True)
    packets = 0
    while True:
        frame = raw.recv(65535)
        payload = udp_payload_from_frame(frame, dport)
        if not payload:
            continue
        out.sendto(payload, fwd)
        packets += 1
        if packets == 1:
            head = payload[:8].hex()
            kind = "mpegts" if payload[:1] == b"\x47" else (
                "rtp" if (payload[0] & 0xC0) == 0x80 else "h264/other"
            )
            print(
                f"[video-udp-relay] first packet len={len(payload)} "
                f"type={kind} head={head}",
                flush=True,
            )


if __name__ == "__main__":
    raise SystemExit(main())
