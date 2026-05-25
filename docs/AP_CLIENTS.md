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

AP clients get internet via NAT (`setup-nat.sh`). Access from phones (`192.168.54.0/24`) to the drone radio subnet **192.168.53.0/24** is forwarded and masqueraded through `eth0`, so ArduPilot/sonar do not need a return route to the AP subnet.

## Concurrent AP + wlan0 client

**uap0** (AP) and **wlan0** (internet) work **at the same time** on one radio — not “AP off → Wi‑Fi on”. Both interfaces stay up; only the channel is shared.

```
phy#0  one channel only (#channels <= 1)
  wlan0  managed  →  router (e.g. Coco ch11)  — internet
  uap0   AP       →  CaimanHS                     — phones
```

**Same channel rule**:

| Router (wlan0 client) | AP (uap0 / hostapd) |
|----------------------|---------------------|
| 2.4 GHz channel 6    | channel 6, `hw_mode=g` |
| 2.4 GHz channel 11   | channel 11, `hw_mode=g` |
| 5 GHz channel 36     | channel 36, `hw_mode=a` |

Different channels at the same time — **impossible** on this adapter.

AP channel policy:

- If **wlan0 is already connected**, `start-drone-hotspot.sh` starts AP in `concurrent` mode: it reads `freq` + `channel` from `iw dev wlan0 link`, configures hostapd to the same channel, and keepalive may reconnect wlan0 only on that channel.
- If **wlan0 is not connected**, AP starts in `standalone` mode on the least busy 2.4 GHz non-overlapping channel (`1/6/11`); keepalive does **not** touch wlan0 until AP is off.
- AP channel selection never writes channel/band/BSSID pins into saved NetworkManager Wi-Fi profiles.

`gcs-wlan-keepalive.timer` reconnects wlan0 every 20s only in `concurrent` mode.

No manual setup required: scripts try all NetworkManager Wi‑Fi profiles (autoconnect first). Optional preference:

```bash
# optional — try this profile first
GCS_WLAN_CONNECTION=Coco
```

### Boot / AP on sequence

1. If **wlan0** is connected, read its channel; otherwise scan and choose a free AP channel.
2. Configure **hostapd** (`hw_mode` + `channel`) only.
3. Start **uap0** AP.
4. In `concurrent` mode only, try to reconnect **wlan0** on the AP channel without modifying saved NM profiles.

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
| AP off | Saved Wi-Fi profile channels are untouched; wlan0 can reconnect normally |
| `GCS_WLAN_CONNECTION` | Optional priority, not required |

Do not use the AP SSID (CaimanHS) as client profile.

**AP off at boot:** `gcs-ap-default-off.service` creates `/var/lib/gcs-ap/manual-off` before `drone-hotspot`. Enable AP only from tray / `toggle-ap.sh`.

**Duplicate NM profiles** (`CuCu`): created when NetworkManager renames a profile after failed `connection modify`. Run `sudo cleanup-nm-wifi-duplicates.sh`.

### Troubleshooting

| Symptom | Fix |
|---------|-----|
| AP won't start, `unknown configuration item 'noscan'` | `sudo ensure-hostapd-concurrent.sh` (removes invalid `noscan` from hostapd 2.10) |
| Wi‑Fi dead after AP off | `sudo fix-wlan-after-ap.sh` |
| AP off also kills Wi‑Fi | Update stop scripts: `sudo ./scripts/install-ap-tray.sh`; AP stop now restores `wlan0` outside the systemd stop timeout |
| `restore-wlan-client.sh --recover` breaks saved Wi‑Fi profile | Update scripts: restore is now non-mutating and no longer edits NM profile channel/band/bssid/keyfiles |
| Only AP or only Wi‑Fi works | `sudo ./scripts/install-ap-tray.sh` then toggle AP |
| `network could not be found` | First check txpower/radio. `repair-wifi-profile.sh` is safe now: it uses a temporary profile and keeps the original unless the replacement connects |

**Recreate profile (fixes immutable `seen-bssids` on NM 1.36):**

```bash
sudo ./scripts/repair-wifi-profile.sh CoCo
# or manual:
PSK=$(sudo nmcli -s -g 802-11-wireless-security.psk connection show CoCo)
sudo nmcli connection delete CoCo
sudo nmcli device wifi connect "CoCo" password "$PSK" ifname wlan0 bssid 2C:58:4F:95:06:CB
iw dev wlan0 link
```

Use the BSSID from `nmcli device wifi list ifname wlan0 | grep CoCo` (5 GHz `…CB`, not old 2.4 GHz `…CA`).

**Auth timeout / still `ssid-not-found` after recreate:** check `iw dev wlan0 info` — if `txpower` is ~**3 dBm**, restore it then reconnect:

```bash
sudo iw reg set DE
sudo iw dev wlan0 set txpower auto
iw dev wlan0 info | grep txpower
sudo nmcli connection up CoCo ifname wlan0 ap 2C:58:4F:95:06:CB
```

If txpower stays at 3 dBm: `sudo modprobe -r mt7921e && sudo modprobe mt7921e`, then retry.

Install/update scripts:

```bash
cd ~/MAV_widget
sudo ./scripts/install-ap-tray.sh
sudo ./scripts/ensure-hostapd-concurrent.sh
sudo systemctl reset-failed hostapd drone-hotspot
sudo systemctl restart drone-hotspot
```

