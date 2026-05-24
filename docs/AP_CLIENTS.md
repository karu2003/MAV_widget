# Wi‑Fi AP clients (MAVLink + video)

Network **CaimanHS**, gateway **192.168.54.1**, DHCP **192.168.54.10–100**.

## MAVLink (MAVProxy)

Telemetry is **broadcast** to the AP subnet:

```text
--out=udpbcast:192.168.54.255:14550
```

Commands from phones/tablets are accepted on the GCS AP address:

```text
--out=udpin:192.168.54.1:14550
```

When the AP is enabled, MAVProxy is restarted automatically (`restart-ap-streaming.sh`).

### QGroundControl on an AP client

1. Connect to Wi‑Fi **CaimanHS**.
2. **Comm Links** → UDP, port **14550**, mode **Listen** (or host **192.168.54.1**, port **14550**).
3. On the Winmate GCS, disable **AutoConnect UDP** on port 14550 in QGC (see [MAVPROXY_QGC.md](MAVPROXY_QGC.md)).

Verify on the GCS:

```bash
check-ap-stream.sh
```

## Video (RTSP)

The drone sends **RTP H.264** on UDP **5600** (not MPEG-TS). On the GCS, QGroundControl keeps port **5600**; **`gcs-video-udp-relay`** copies packets from `eth0` to `127.0.0.1:5601`, and **ffmpeg** publishes into **MediaMTX** for AP clients:

```text
rtsp://192.168.54.1:8554/stream
```

Install MediaMTX once:

```bash
sudo install-mediamtx.sh
sudo systemctl restart gcs-video-udp-relay gcs-video-rtsp
check-ap-stream.sh
```

Configuration: `/etc/default/gcs-ap-streaming`

| Variable | Default |
|----------|---------|
| `VIDEO_MODE` | `udp` |
| `VIDEO_UDP_PORT` | `5601` (relay copy; QGC uses `5600`) |
| `VIDEO_MODE=v4l2` | local camera `/dev/video0` |
| `VIDEO_MODE=test` | test pattern (debug) |

Services:

```bash
sudo systemctl enable --now gcs-video-udp-relay gcs-video-rtsp
sudo journalctl -u gcs-video-rtsp -u gcs-video-udp-relay -f
```

### QGC — video

**Settings → Video** → **Video Source**: RTSP Video Stream  
**RTSP URL:**

`rtsp://192.168.54.1:8554/stream`

VLC on a phone: same URL (`ffplay -rtsp_transport tcp …` on the GCS may show 404 until ffmpeg is actively publishing).

## Ports

| Service | Port | Interface |
|---------|------|-----------|
| MAVLink broadcast | 14550/udp | 192.168.54.255 |
| MAVLink uplink | 14550/udp | 192.168.54.1 |
| RTSP | 8554/tcp | 192.168.54.1 |
| Video from drone | 5600/udp | eth0 (companion → GCS) |
| Video relay (local) | 5601/udp | 127.0.0.1 (ffmpeg RTP ingest) |

AP clients get internet via NAT (`setup-nat.sh`). Direct access to the drone radio subnet **192.168.53.0/24** is forwarded between `uap0` and `eth0`.

## Concurrent AP + wlan0 client

The GCS uses **uap0** (AP for phones) and **wlan0** (internet uplink) on the same radio. After boot, `restore-wlan-client.sh` reconnects wlan0 via NetworkManager.

Set your home/office Wi‑Fi profile in `/etc/default/gcs-ap-streaming`:

```bash
GCS_WLAN_CONNECTION=Coco
```

(Use `nmcli connection show` to list profiles; do not use the AP SSID from hostapd.)

