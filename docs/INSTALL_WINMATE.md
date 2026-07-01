# Winmate GCS — Install From Scratch

Complete setup for a **Winmate GCS** with a **built‑in Microhard radio on `usb0`**
(RNDIS/USB‑Ethernet), an on‑board Ethernet WAN, and a Wi‑Fi Access Point for
phones. This is the "everything works out of the box" guide.

> If your radio is an external USB‑Ethernet adapter that must be renamed to
> `eth0` (dev‑board layout), use [../INSTALL.md](../INSTALL.md) instead. The two
> layouts differ only in the network role config; everything else is identical.

---

## 1. Topology

```
                 ┌─────────────────────── Winmate GCS ───────────────────────┐
   Drone         │  usb0  192.168.53.1/24   ← built‑in Microhard radio        │
 (companion  ────┼─►  MAVLink   udp 14550                                     │
 192.168.53.201) │    Video     udp 5600  (H.264/RTP)                         │
                 │                                                            │
                 │  eth0  WAN (DHCP)        ← internet uplink                 │
                 │  wlan0 Wi‑Fi client      ← optional internet uplink        │
                 │  uap0  192.168.54.1/24   ← AP for phones (SSID caimanHD)   │
                 └────────────────────────────────────────────────────────────┘
                                     │ Wi‑Fi
                                     ▼
                              Phones (QGC): MAVLink + RTSP video
```

| Interface | Role | Address |
|-----------|------|---------|
| `usb0`  | Built‑in Microhard radio to the drone | `192.168.53.1/24` |
| `eth0`  | Ethernet WAN (internet)                | DHCP |
| `wlan0` | Wi‑Fi client (optional internet)       | DHCP |
| `uap0`  | Access Point for phones                | `192.168.54.1/24` |

### 1.1 Drone / companion side (what to send)

The companion computer on the drone reaches the GCS across the Microhard radio
link. Give the companion an address on the same subnet (e.g.
`192.168.53.201/24`, gateway `192.168.53.1`) and stream to the GCS radio IP:

| Stream | Destination | Format |
|--------|-------------|--------|
| **MAVLink** | `192.168.53.1:14550` (UDP) | MAVLink 2 |
| **Video**   | `192.168.53.1:5600` (UDP)  | H.264 / RTP, payload type 96 |

Notes:
- Send **to `192.168.53.1`** (the GCS), *not* to a broadcast address.
- MAVProxy owns `192.168.53.1:14550` and fans telemetry out to the local QGC,
  the widget and every AP phone — the companion only needs this one target.
- Video port is **5600** (QGC's default). Example companion pipeline:

  ```bash
  # GStreamer (companion → GCS)
  gst-launch-1.0 <camera> ! ... ! x264enc tune=zerolatency bitrate=2000 \
      ! rtph264pay config-interval=1 pt=96 \
      ! udpsink host=192.168.53.1 port=5600
  ```

  Any encoder works as long as it sends **H.264 in RTP (pt=96)** to
  `192.168.53.1:5600`.

---

## 2. Prerequisites

- Ubuntu 22.04 (or similar) with **NetworkManager** and a **graphical login**
  (systemd *user* services run in the desktop session).
- Python 3.10+.
- `sudo`/root access for the one‑time provisioning.
- Internet on `eth0` or `wlan0` during install (to fetch packages).

```bash
cd ~
git clone <repo-url> MAV_widget      # or use an existing ~/MAV_widget
cd ~/MAV_widget
pip install -r requirements.txt
```

---

## 3. One‑command provisioning

Everything below (packages, AP, MAVLink, video, autostart) is installed by a
single idempotent script. Provide the AP SSID and WPA2 passphrase inline:

```bash
sudo AP_SSID=caimanHD AP_PASS='123456789' ./scripts/provision-ap-winmate.sh
```

The passphrase is **never** stored in git — it is written only to
`/etc/hostapd/drone-hotspot.conf` (mode `0600`). See [SECRETS.md](SECRETS.md).

### What it does

1. **Packages**
   - `hostapd`, `iw`, `dnsmasq` (full package, not just `dnsmasq-base`)
   - `gir1.2-ayatanaappindicator3-0.1` — AP tray icon
   - **`gstreamer1.0-plugins-bad`** (`h264parse`),
     **`gstreamer1.0-libav`** (`avdec_h264`),
     **`gstreamer1.0-qt5`** (`qmlglsink`) — required by QGC's local video pane
2. **Interface roles** → installs `config/gcs-ap-streaming.winmate.conf` to
   `/etc/default/gcs-ap-streaming` (`RADIO_IF=usb0`, `RADIO_BUILTIN=1`,
   `INTERNET_IFS="eth0 wlan0"`).
3. **hostapd** config with your SSID/passphrase, `DAEMON_CONF` wired up.
4. **`setup_wifi_ap.sh`** — AP tray, systemd units, NAT, dnsmasq, and the
   NetworkManager `unmanaged-devices=uap0` rule (see §6.1).
5. **`setup_autostart.sh`** — installs and enables the user services
   `mavproxy-gcs`, `mav-widget`, and **`mav-ap-fanout`** (see §5).

The AP is **OFF by default** at every boot — turn it on from the tray or with
`toggle-ap.sh`.

---

## 4. MAVLink architecture

```
Drone  --udp-->  usb0 192.168.53.1:14550   (MAVProxy master, only owner)
                          │
                       MAVProxy  (mavproxy-gcs.service)
        ┌─────────────┬───┴────────────┬──────────────────────┐
   127.0.0.1:14550  127.0.0.1:14552   127.0.0.1:14545          │
        │              │                │                       │
   local QGC        MAV_Widget     mav-ap-fanout.service ──► every phone :14550
                                    (owns 192.168.54.1:14550, unicast per client)
```

| Consumer | Port | Notes |
|----------|------|-------|
| Drone → GCS | `usb0 192.168.53.1:14550` | MAVProxy `--master` (sole owner) |
| Local QGC | `127.0.0.1:14550` | QGC AutoConnect UDP; MAVProxy `--out=udp:127.0.0.1:14550` |
| MAV_Widget | `127.0.0.1:14552` | MAVProxy `--out=127.0.0.1:14552` |
| AP fan‑out feed | `127.0.0.1:14545` | MAVProxy `--out=udp:127.0.0.1:14545` |
| AP phones | each phone `:14550` | `mav-ap-fanout.py` unicasts to every DHCP‑leased client |

### Why unicast fan‑out (not `udpbcast`)

pymavlink's `udpbcast` output stops broadcasting after the **first reply**: it
latches onto that sender and disables broadcast. On the GCS the local QGC
(`0.0.0.0:14550`) answers first, so the socket locks onto `127.0.0.1` and no
phone ever receives telemetry. Wi‑Fi broadcast is also frequently dropped by
Android. `mav-ap-fanout.py` unicasts to **every** connected client (from the
`dnsmasq` lease file plus any client that talks to it), which is reliable for
**many** simultaneous phones and forwards their uplink back to the drone.

---

## 5. Video

Two independent paths, both fed by the drone's H.264/RTP stream on **`usb0:5600`**:

```
Drone --H.264/RTP--> usb0 192.168.53.1:5600
        │
        ├── local QGC binds 0.0.0.0:5600 directly (UDP h.264)
        │
        └── video-udp-relay.py  RAW‑taps :5600  ──► 127.0.0.1:5601
                                                      │
                              ffmpeg (SDP) ──► MediaMTX RTSP
                                                      │
                                    rtsp://192.168.54.1:8554/stream  (phones)
```

- The relay uses a **RAW packet socket**, so it copies the stream *without*
  consuming it — local QGC keeps receiving on `:5600` unchanged.
- Key setting in `/etc/default/gcs-ap-streaming`:
  `VIDEO_UDP_PORT=5600` (drone's port), `VIDEO_FWD_PORT=5601` (internal to
  ffmpeg), `VIDEO_IFACE=usb0`.

---

## 6. QGroundControl configuration (local GCS)

### 6.1 MAVLink
- **Settings → General → AutoConnect**: *AutoConnect to UDP* enabled is fine —
  QGC listens on `0.0.0.0:14550` and MAVProxy feeds it there.
  (You may instead use a manual UDP link on `14551`.)

### 6.2 Video
- **Settings → General → Video**
  - **Source:** `UDP h.264 Video Stream`
  - **Port:** `5600`
  - **URL/Host:** *empty* — QGC binds `0.0.0.0:5600` and receives directly from
    the drone. Do **not** enter `127.0.0.1`.
- Open the **Fly view** — QGC only starts the GStreamer receiver (and binds
  `:5600`) when the flight video pane is shown.

### 6.3 Desktop launcher icon
If the QGC desktop icon is blank, the hicolor icon cache is stale. Either point
the launcher at the file directly (no root):

```ini
# ~/Desktop/QGroundControl.desktop
Icon=/usr/share/icons/hicolor/128x128/apps/QGroundControl.png
```

…or rebuild the cache globally (fixes the app grid / task bar too):

```bash
sudo gtk-update-icon-cache -f /usr/share/icons/hicolor
```

---

## 7. Access Point & phones

- SSID / password: whatever you passed to the provisioner (e.g. `caimanHD` /
  `123456789`), stored in `/etc/hostapd/drone-hotspot.conf`.
- Turn the AP on: **tray icon** (right‑click → AP on) or `toggle-ap.sh`.
- Phone gets an IP in `192.168.54.10–100` via DHCP (`dnsmasq`).
- On the phone's QGC:
  - **MAVLink:** works automatically — the fan‑out unicasts telemetry to the
    phone on `:14550`.
  - **Video:** `Source = RTSP Video Stream`, URL `rtsp://192.168.54.1:8554/stream`.

### 7.1 Why the AP kept losing its IP (fixed by provisioning)

NetworkManager manages `uap0` by default and flushes `192.168.54.1` ~2 s after
it is assigned, which makes `dnsmasq` fail with *"unknown interface uap0"* and
phones get no DHCP. The provisioner installs
`/etc/NetworkManager/conf.d/gcs-concurrent-wifi.conf` with
`unmanaged-devices=interface-name:uap0` and reloads NetworkManager, so the AP
address is stable.

---

## 8. Verify

```bash
# Interfaces & AP
ip -br addr show usb0 uap0
systemctl is-active hostapd dnsmasq drone-hotspot
nmcli device status | grep uap0        # must be "unmanaged"

# MAVLink user services
systemctl --user is-active mavproxy-gcs mav-widget mav-ap-fanout
pgrep -af '[m]avproxy.py' | tr ' ' '\n' | grep -E 'out=|master='

# Telemetry reaching local consumers
python3 - <<'PY'
from pymavlink import mavutil
for p in (14550, 14552):
    m = mavutil.mavlink_connection(f"udp:127.0.0.1:{p}")
    print(p, "OK" if m.wait_heartbeat(timeout=5) else "no heartbeat"); m.close()
PY

# Video
systemctl is-active gcs-video-udp-relay gcs-video-rtsp
journalctl -u gcs-video-udp-relay -n 3 --no-pager    # "usb0 UDP :5600 -> 127.0.0.1:5601"
gst-inspect-1.0 avdec_h264 h264parse qmlglsink >/dev/null && echo "QGC video plugins OK"
```

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Phone gets no DHCP / "IP Error" | NM flushes `uap0` IP → `dnsmasq` fails | Re‑run provisioning, or `sudo nmcli general reload && sudo systemctl restart drone-hotspot` (needs `unmanaged-devices=uap0`) |
| MAVLink works locally, phone has none | `udpbcast` latched onto local QGC | Ensure `mav-ap-fanout.service` is active; `systemctl --user restart mav-ap-fanout` |
| No video on **phone** | Relay tapping wrong port | `VIDEO_UDP_PORT=5600` in `/etc/default/gcs-ap-streaming`, then `sudo systemctl restart gcs-video-udp-relay gcs-video-rtsp` |
| No video in **local QGC** | Missing GStreamer plugins | `sudo apt-get install -y gstreamer1.0-plugins-bad gstreamer1.0-libav gstreamer1.0-qt5`, restart QGC, open Fly view |
| QGC shows no vehicle | QGC steals `14550` / MAVProxy not linked | See [MAVPROXY_QGC.md](MAVPROXY_QGC.md) |
| Blank QGC desktop icon | Stale hicolor icon cache | Absolute `Icon=` path or `sudo gtk-update-icon-cache -f /usr/share/icons/hicolor` |
| `unknown configuration item 'noscan'` | hostapd 2.10 | `sudo ensure-hostapd-concurrent.sh` |
| AP up but Wi‑Fi client dead | single‑radio channel conflict | Tray → Reconnect Wi‑Fi client, or `sudo fix-wlan-after-ap.sh` |

More detail: [AP_CLIENTS.md](AP_CLIENTS.md) · [MAVPROXY_QGC.md](MAVPROXY_QGC.md) · [SECRETS.md](SECRETS.md)

---

## 10. Update after `git pull`

```bash
cd ~/MAV_widget
sudo AP_SSID=caimanHD AP_PASS='123456789' ./scripts/provision-ap-winmate.sh
# or, without touching the AP secret, just the user services:
./setup_autostart.sh
systemctl --user restart mavproxy-gcs mav-widget mav-ap-fanout
```
