# Installation (GCS / Winmate)

Step-by-step setup for MAV widget, MAVProxy, Wi‑Fi AP, and **concurrent** wlan0 client + AP on one radio.

---

## 1. Prerequisites

- Linux with NetworkManager, `hostapd`, `dnsmasq`, `iw`
- Python 3.10+
- User session with systemd user services (graphical login)
- Wi‑Fi profiles saved in NetworkManager (`nmcli connection show`)

Clone or copy the project:

```bash
cd ~
git clone <repo-url> MAV_widget   # or use existing ~/MAV_widget
cd ~/MAV_widget
```

---

## 2. Python dependencies

```bash
pip install -r requirements.txt
```

Optional: verify joystick

```bash
python3 probe_input.py
python3 widget.py --no-joystick   # overlay only
```

---

## 3. Network (eth0 / eth1)

Radio port **eth0** must be `192.168.53.1/24`. Interface names are fixed via systemd `.link` files.

```bash
sudo ./scripts/setup_network.sh
sudo reboot
check-network.sh
```

| Interface | Role |
|-----------|------|
| `eth0` | Radio to drone — `192.168.53.1/24` |
| `eth1` | USB debug internet (DHCP) |
| `wlan0` | Wi‑Fi client (internet uplink) |
| `uap0` | AP for phones — `192.168.54.1/24` |

---

## 4. Wi‑Fi AP + concurrent client (wlan0 + uap0)

The adapter (MT7921) supports **STA + AP at the same time** on **one channel**:

```
phy#0  (#channels <= 1)
  wlan0  managed  →  router (internet)
  uap0   AP       →  CaimanHS (phones)
```

**Same channel rule** — if wlan0 is connected, AP matches the router channel:

| Router (wlan0) | AP (hostapd / uap0) |
|----------------|---------------------|
| 2.4 GHz ch 6   | `channel=6`, `hw_mode=g` |
| 2.4 GHz ch 11  | `channel=11`, `hw_mode=g` |
| 5 GHz ch 36    | `channel=36`, `hw_mode=a` |

Different channels simultaneously — **not possible** on this hardware.

If wlan0 is not connected when AP starts, AP chooses the least busy 2.4 GHz
channel (`1/6/11`) in standalone mode. In standalone mode keepalive does not
touch wlan0 until AP is off. AP startup never writes channel/band/BSSID pins
into saved NetworkManager Wi-Fi profiles.

### 4.1 First-time AP install

```bash
cd ~/MAV_widget
sudo ./setup_wifi_ap.sh
```

This installs:

- `drone-hotspot.service` — creates `uap0`, syncs channel from wlan0, starts hostapd/dnsmasq
- NAT (`setup-nat.sh`) — internet from `wlan0`/`eth1` to AP clients
- `gcs-wlan-keepalive.timer` — keeps wlan0 up while AP runs (every 20 s)
- AP tray icon (`gcs-ap-tray.service`)

**Reboot** after first network/AP install if prompted.

### 4.2 AP secrets (on device only)

SSID and WPA password live in `/etc/hostapd/drone-hotspot.conf` (not in git). See [docs/SECRETS.md](docs/SECRETS.md).

### 4.3 Update scripts only (after git pull)

```bash
cd ~/MAV_widget
sudo ./scripts/install-ap-tray.sh
sudo ./scripts/ensure-hostapd-concurrent.sh   # removes invalid noscan=1 (hostapd 2.10)
sudo systemctl daemon-reload
sudo systemctl reset-failed hostapd drone-hotspot
sudo systemctl restart drone-hotspot
sudo systemctl enable --now gcs-wlan-keepalive.timer
```

### 4.4 Optional: prefer one Wi‑Fi profile

Any saved profile works. To try one first:

```bash
sudo ./scripts/configure-wlan-client.sh Coco
# or clear preference:
sudo ./scripts/configure-wlan-client.sh
# (empty name → auto)
```

Set in `/etc/default/gcs-ap-streaming`: `GCS_WLAN_CONNECTION=ProfileName`

### 4.5 AP control

AP is **off by default at every boot** (`gcs-ap-default-off.service` sets `manual-off`). Turn on only from tray or `toggle-ap.sh`.

- **Tray icon** (top panel) — right-click: AP on/off, Reconnect Wi‑Fi client, Settings
- Terminal: `toggle-ap.sh`

### 4.6 Verify concurrent mode

Both must be up **at the same time** on the **same channel**:

```bash
iw dev wlan0 link          # freq 2462 → channel 11
grep -E '^(channel|hw_mode)=' /etc/hostapd/drone-hotspot.conf
iw dev uap0 info           # channel 11 (2462 MHz)
nmcli device status        # wlan0 connected, uap0 unmanaged
systemctl is-active hostapd
check-gcs-link.sh
```

Example (working):

```text
wlan0: Coco, freq 2462 (ch 11)
hostapd: channel=11, hw_mode=g
uap0: CaimanHS, channel 11
```

### 4.7 Troubleshooting Wi‑Fi + AP

| Symptom | Fix |
|---------|-----|
| `unknown configuration item 'noscan'` | `sudo ensure-hostapd-concurrent.sh` |
| AP on ch 6, router on ch 11 | Restart AP after wlan0 connected: `sudo systemctl restart drone-hotspot` |
| Wi‑Fi dead after AP off | `sudo fix-wlan-after-ap.sh` |
| Profile `CuCu` (duplicate) | `sudo cleanup-nm-wifi-duplicates.sh` |
| AP starts at boot unwanted | `sudo systemctl enable gcs-ap-default-off.service` |
| wlan0 down, AP still on | Tray → **Reconnect Wi‑Fi client**, or wait for keepalive (~20 s) |
| Only AP, no internet on wlan0 | Router must be on **same channel** as AP while both run |

More detail: [docs/AP_CLIENTS.md](docs/AP_CLIENTS.md)

---

## 5. MAVProxy + widget autostart

```bash
cd ~/MAV_widget
./setup_autostart.sh
systemctl --user enable --now mavproxy-gcs mav-widget
```

Boot order after graphical login:

1. `drone-hotspot.service` (AP, if not manual-off)
2. `mavproxy-gcs.service` — master `udpin:192.168.53.1:14550`, out `127.0.0.1:14551/14552`
3. `mav-widget.service` — overlay on `udp:127.0.0.1:14552`

Logs:

```bash
systemctl --user status mavproxy-gcs mav-widget
tail -f ~/.local/state/mav-gcs/mav-widget.log
tail -f ~/.local/state/mav-gcs/mavproxy-gcs.log
```

QGC: UDP **14551**, disable AutoConnect on 14550 — [docs/MAVPROXY_QGC.md](docs/MAVPROXY_QGC.md)

---

## 6. Video for AP clients (optional)

```bash
sudo ./scripts/install-mediamtx.sh
sudo systemctl enable --now gcs-video-udp-relay gcs-video-rtsp
check-ap-stream.sh
```

RTSP: `rtsp://192.168.54.1:8554/stream`

---

## 7. Full install checklist

Run once on a new GCS:

```bash
cd ~/MAV_widget
pip install -r requirements.txt
sudo ./scripts/setup_network.sh
sudo reboot
# after reboot:
sudo ./setup_wifi_ap.sh
./setup_autostart.sh
sudo ./scripts/ensure-hostapd-concurrent.sh
sudo systemctl enable --now gcs-wlan-keepalive.timer
check-gcs-link.sh
check-ap-stream.sh
systemctl --user status mavproxy-gcs mav-widget gcs-ap-tray
```

---

## 8. Useful commands

| Command | Purpose |
|---------|---------|
| `check-gcs-link.sh` | wlan0 + MAVProxy + widget |
| `check-ap-stream.sh` | AP MAVLink + RTSP |
| `check-nat.sh` | NAT uplinks |
| `toggle-ap.sh` | AP on/off |
| `fix-wlan-after-ap.sh` | Restore wlan0 after AP off |
| `mav-gcs-logs.sh -f` | Follow GCS logs |
