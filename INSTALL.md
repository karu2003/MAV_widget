# Installation (GCS / Winmate)

> **Winmate GCS with a built‑in radio on `usb0`?** Use the complete from‑scratch
> guide — one command installs everything (AP, MAVLink unicast fan‑out, video,
> autostart): **[docs/INSTALL_WINMATE.md](docs/INSTALL_WINMATE.md)**.
> The guide below covers the dev‑board layout (external USB‑Ethernet radio
> renamed to `eth0`).

---

## 1. Prerequisites

- Linux with NetworkManager, `hostapd`, `dnsmasq`, `iw`
- Python 3.10+
- User session with systemd user services (graphical login)
- Wi‑Fi profiles saved in NetworkManager (`nmcli connection show`)

```bash
cd ~
git clone <repo-url> MAV_widget   # or use existing ~/MAV_widget
cd ~/MAV_widget
```

---

## 2. Python dependencies

```bash
pip install -r requirements.txt
python3 probe_input.py            # optional: verify joystick
python3 widget.py --no-joystick   # optional: overlay only
```

---

## 3. Network (eth0 / eth1)

Radio port **eth0** must be `192.168.53.1/24`. Interface names are fixed via systemd `.link` files.

The radio adapter is a **USB-ETH adapter** — MAC address is detected automatically at install time.
No manual MAC configuration needed; the script works on any machine.

```bash
sudo ./scripts/setup_network.sh
sudo reboot
check-network.sh
```

`setup_network.sh` detects the radio USB-ETH adapter automatically (excludes the known USB-debug adapter).
If multiple ethernet adapters are found, the script prompts you to choose.
To force a specific interface: `RADIO_ETH_IFACE=enx001122334455 sudo ./scripts/setup_network.sh`

| Interface | Role |
|-----------|------|
| `eth0` | Radio to drone — `192.168.53.1/24` |
| `eth1` | USB debug internet (DHCP) |
| `wlan0` | Wi‑Fi client (internet uplink) |
| `uap0` | AP for phones — `192.168.54.1/24` |

---

## 4. Wi‑Fi AP + concurrent client (wlan0 + uap0)

MT7921: single radio — wlan0 (STA) + uap0 (AP) on the **same channel**. AP channel follows wlan0 automatically.

### 4.1 First-time AP install

```bash
cd ~/MAV_widget
sudo ./setup_wifi_ap.sh
```

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

```bash
sudo ./scripts/configure-wlan-client.sh Coco
# or clear preference (auto):
sudo ./scripts/configure-wlan-client.sh
```

Set in `/etc/default/gcs-ap-streaming`: `GCS_WLAN_CONNECTION=ProfileName`

### 4.5 AP control

AP is **off by default** at every boot. Turn on via tray or `toggle-ap.sh`.

- **Tray icon** — right-click: AP on/off, Reconnect Wi‑Fi client, Settings
- Terminal: `toggle-ap.sh`

### 4.6 Verify concurrent mode

```bash
iw dev wlan0 link          # freq 2462 → channel 11
grep -E '^(channel|hw_mode)=' /etc/hostapd/drone-hotspot.conf
iw dev uap0 info           # channel 11 (2462 MHz)
nmcli device status        # wlan0 connected, uap0 unmanaged
systemctl is-active hostapd
check-gcs-link.sh
```

### 4.7 Troubleshooting Wi‑Fi + AP

| Symptom | Fix |
|---------|-----|
| `unknown configuration item 'noscan'` | `sudo ensure-hostapd-concurrent.sh` |
| AP on ch 6, router on ch 11 | Restart AP after wlan0 connected: `sudo systemctl restart drone-hotspot` |
| Wi‑Fi dead after AP off | `sudo fix-wlan-after-ap.sh` |
| Profile `CuCu` (duplicate) | `sudo cleanup-nm-wifi-duplicates.sh` |
| AP starts at boot unwanted | `sudo systemctl disable drone-hotspot.service && sudo systemctl enable gcs-ap-default-off.service` |
| wlan0 down, AP still on | Tray → **Reconnect Wi‑Fi client**, or wait for keepalive (~30 s) |
| Only AP, no internet on wlan0 | Router must be on **same channel** as AP while both run |

More detail: [docs/AP_CLIENTS.md](docs/AP_CLIENTS.md)

---

## 5. MAVProxy + widget autostart

```bash
cd ~/MAV_widget
./setup_autostart.sh
systemctl --user enable --now mavproxy-gcs mav-widget
```

Ports: MAVProxy master `udpin:192.168.53.1:14550`, widget `udp:127.0.0.1:14552`, QGC `udp:127.0.0.1:14551`.

```bash
systemctl --user status mavproxy-gcs mav-widget
mav-gcs-logs.sh -f
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
