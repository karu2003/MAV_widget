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

**uap0** (AP) and **wlan0** (internet) work **at the same time** on one radio — not “AP off → Wi‑Fi on”. Both interfaces stay up; only the channel is shared.

```
phy#0  one channel only (#channels <= 1)
  wlan0  managed  →  router (e.g. Coco ch11)  — internet
  uap0   AP       →  CaimanHS                     — phones
```

**Same channel rule** (before hostapd starts):

| Router (wlan0 client) | AP (uap0 / hostapd) |
|----------------------|---------------------|
| 2.4 GHz channel 6    | channel 6, `hw_mode=g` |
| 2.4 GHz channel 11   | channel 11, `hw_mode=g` |
| 5 GHz channel 36     | channel 36, `hw_mode=a` |

Different channels at the same time — **impossible** on this adapter.  
`start-drone-hotspot.sh` connects wlan0, reads `freq` + `channel` from `iw dev wlan0 link`, then writes the same values to `/etc/hostapd/drone-hotspot.conf`. If wlan0 is not connected within 30s → default channel **6**, `hw_mode=g`.

`gcs-wlan-keepalive.timer` reconnects wlan0 every 20s if it drops while AP stays on.

No manual setup required: scripts try all NetworkManager Wi‑Fi profiles (autoconnect first). Optional preference:

```bash
# optional — try this profile first
GCS_WLAN_CONNECTION=Coco
```

### Boot / AP on sequence

1. Connect **wlan0** to any saved profile (Coco, …).
2. Read channel + band → configure **hostapd** (`hw_mode` + `channel`).
3. Start **uap0** AP.
4. Reconnect **wlan0** on the same channel if it dropped.

Tray: **Reconnect Wi‑Fi client (wlan0)**.

```bash
check-gcs-link.sh
iw dev
```

### Limits

| Case | Behaviour |
|------|-----------|
| Any saved NM profile | Auto-tried; first success wins |
| AP on channel N | Client must use a network on **same channel N** |
| Router on different channel | Not visible while AP is on — pick another profile or turn AP off briefly |
| `GCS_WLAN_CONNECTION` | Optional priority, not required |

Do not use the AP SSID (CaimanHS) as client profile.

### Troubleshooting

| Symptom | Fix |
|---------|-----|
| AP won't start, `unknown configuration item 'noscan'` | `sudo ensure-hostapd-concurrent.sh` (removes invalid `noscan` from hostapd 2.10) |
| Wi‑Fi dead after AP off | `sudo fix-wlan-after-ap.sh` |
| Only AP or only Wi‑Fi works | `sudo ./scripts/install-ap-tray.sh` then toggle AP |
| `journalctl -u hostapd` shows channel errors | wlan0 must connect first; AP copies its channel |

Install/update scripts:

```bash
cd ~/MAV_widget
sudo ./scripts/install-ap-tray.sh
sudo ./scripts/ensure-hostapd-concurrent.sh
sudo systemctl reset-failed hostapd drone-hotspot
sudo systemctl restart drone-hotspot
```

