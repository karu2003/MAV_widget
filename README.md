# MAV_widget

Background service and overlay widget: Winmate GCS joystick → `RC_CHANNELS_OVERRIDE` + MAVLink telemetry for ArduPilot on Linux.

![Python 3.10+](https://img.shields.io/badge/Python-3.10+-blue)
![MAVLink 2](https://img.shields.io/badge/MAVLink-2-green)
![Platform](https://img.shields.io/badge/Platform-Linux-orange)
![License](https://img.shields.io/badge/License-MIT-lightgrey)

---

## What it does

- Reads the Winmate GCS Joystick (or any Linux input device) via `evdev`
- Sends `RC_CHANNELS_OVERRIDE` to ArduPilot at 50 Hz through MAVProxy — **independent of QGC**
- Displays an always-on-top telemetry overlay in the **top-right corner** of the screen (210×280 px)
- Parses drone state from MAVLink (`HEARTBEAT`, `ATTITUDE`, `SYS_STATUS`, `GPS_RAW_INT`, `VFR_HUD`)

```
/dev/input/eventX  →  widget.py / joystick_reader.py  →  RC_CHANNELS_OVERRIDE (50 Hz)  →  MAVProxy  →  ArduPilot
ArduPilot :14550  →  MAVProxy only (master)
                    ├─ 14551 → QGC
                    └─ 14552 → widget (telemetry + RC)
```

---

## Repository layout

```
MAV_widget/
├── widget.py              # Tkinter telemetry overlay + main entry point
├── joystick_reader.py     # evdev joystick reader (auto-detect Winmate)
├── mavlink_link.py        # MAVLink RX + RC override TX (50 Hz)
├── drone_state.py         # shared telemetry and joystick state
├── config.py              # axis/button mapping, MAVLink URI, RC channels
├── probe_input.py         # interactive input device probe tool
├── test_joystick.py       # quick joystick test
├── requirements.txt
├── docs/
│   ├── MAVPROXY_QGC.md    # MAVProxy + QGC port setup and troubleshooting
│   ├── AP_CLIENTS.md      # MAVLink + RTSP for Wi‑Fi AP clients
│   └── SECRETS.md         # what must not be committed (passwords, keys)
├── INSTALL.md             # full GCS installation (network, AP, concurrent Wi‑Fi)
├── scripts/
│   ├── run_widget.sh           # launch widget immediately (no MAVProxy wait)
│   ├── start_mavproxy.sh       # start MAVProxy daemon
│   ├── wait_gcs_ready.sh       # fast hostapd / MAVProxy / heartbeat waits
│   ├── wait_mavproxy_link.sh   # wrapper for optional heartbeat wait
│   ├── autostart-gcs.sh        # manual / legacy → mavproxy-gcs.service
│   ├── toggle-screen-lock.sh   # kiosk mode on/off
│   ├── start-drone-hotspot.sh
│   ├── stop-drone-hotspot.sh
│   ├── toggle-ap.sh            # AP on/off (called by tray)
│   ├── gcs-ap-tray.py          # top panel tray icon
│   ├── install-ap-tray.sh      # install tray + toggle only
│   ├── video-udp-relay.py      # eth0:5600 → 127.0.0.1:5601 (RTP copy)
│   ├── start-video-rtsp.sh     # MediaMTX + ffmpeg RTP → RTSP on AP
│   ├── check-ap-stream.sh      # verify AP MAVLink + video relay
│   └── install-mediamtx.sh
├── systemd/
│   ├── mavproxy-gcs.service    # MAVProxy on login (independent of widget)
│   ├── mav-widget.service
│   └── drone-hotspot.service
├── setup_autostart.sh     # install widget user service
└── setup_wifi_ap.sh       # install Wi-Fi AP boot service
```

---

## Components

### widget.py

Main application. Connects to MAVProxy on `udp:127.0.0.1:14552` for telemetry and RC. Port **14550** is MAVProxy master only — do not point the widget or QGC at it.

**Overlay window**

| Property | Value |
|---|---|
| Size | 210 × 280 px |
| Position | Top-right of the primary screen (20 px margin) |
| Flags | Always on top, no window decorations |
| Content | Link status, flight mode, battery, GPS, attitude, stick values, button states |

Position is computed at startup from `root.winfo_screenwidth()`. Override with `--geometry +X+Y` if needed (Tk format: offset from top-left).

```bash
python3 widget.py                    # top-right (default)
python3 widget.py --geometry +20+20  # fixed position
```

### joystick_reader.py

Reads stick axes and buttons from `/dev/input/eventX` using `evdev`. Auto-detects the Winmate GCS Joystick by name. Seeds initial axis values on open.

### mavlink_link.py

MAVLink connection: parses telemetry in a background thread and sends `RC_CHANNELS_OVERRIDE` at 50 Hz when the joystick is active. RC is sent through MAVProxy with `target_component=1` (autopilot).

### config.py

Winmate GCS Joystick layout (verified manually):

| Stick | evdev | RC channel |
|---|---|---|
| Left X | `ABS_X` | 1 — roll |
| Left Y | `ABS_Y` | 2 — pitch |
| Right X | `ABS_Z` | 4 — yaw |
| Right Y | `ABS_RX` | 3 — throttle |

| Button | RC channel |
|---|---|
| Left top (`BTN_NORTH`) | 5 |
| Left middle (`BTN_WEST`) | 6 |
| Left bottom (`BTN_TL2`) | 7 |
| Left side (`BTN_C`) | 8 |
| Right top (`BTN_TL`) | 9 |
| Right bottom (`BTN_TR`) | 10 |
| Right side (`BTN_Z`) | 11 |
| Left stick press (`BTN_A`) | 12 |
| Right stick press (`BTN_B`) | 13 |

Vertical axes (`ABS_Y`, `ABS_RX`) are inverted in software — see `AXIS_INVERT` in `config.py`.

---

## Installation

Full GCS setup (network, concurrent Wi‑Fi + AP, MAVProxy, widget, autostart): **[INSTALL.md](INSTALL.md)**

---

## Quick start

### Install dependencies

```bash
pip install -r requirements.txt
```

### Find the joystick device

```bash
python3 probe_input.py
# or
python3 -c "from evdev import list_devices, InputDevice
for p in list_devices():
    d = InputDevice(p)
    if 'Joystick' in d.name: print(p, d.name)"
```

> **Note:** `/dev/input/eventX` may change after reboot. The widget auto-detects the Winmate joystick by name.

### Run the widget

```bash
python3 widget.py
python3 widget.py -v                     # verbose logging
python3 widget.py --no-joystick          # telemetry only, no RC override
python3 widget.py --device /dev/input/event9
python3 widget.py --geometry +100+50    # manual position (default: top-right)
```

`run_widget.sh` starts the overlay **immediately**. MAVProxy and the drone link are independent — `mavlink_link.py` reconnects in the background (shows **NO LINK** until telemetry arrives).

### MAVProxy and QGC (required)

MAVProxy is the **only** process that talks to the drone on UDP **14550**. QGC and the widget receive a forwarded copy on separate local ports.

| Port | Address | Client |
|---|---|---|
| 14550 | `192.168.53.1` | MAVProxy `--master` (radio / eth0 to drone) |
| 14551 | `127.0.0.1` | QGroundControl (listen) |
| 14552 | `127.0.0.1` | This widget (telemetry + RC) |

Start MAVProxy (same as `scripts/autostart-gcs.sh`):

```bash
python3 ~/.local/bin/mavproxy.py \
    --master=udpin:192.168.53.1:14550 \
    --out=127.0.0.1:14551 \
    --out=127.0.0.1:14552 \
    --out=udpbcast:192.168.54.255:14550 \
    --out=udpin:192.168.54.1:14550 \
    --nowait \
    --force-connected \
    --non-interactive
```

See [docs/MAVPROXY_QGC.md](docs/MAVPROXY_QGC.md) for official MAVProxy/QGC references and troubleshooting (`mav.tlog` empty, no telemetry, port conflicts).

### QGC connection settings

| Setting | Value |
|---|---|
| Type | UDP |
| Port | **14551** (Listen) |
| **Disable** | **Settings → General → AutoConnect to UDP** (QGC otherwise binds **14550** and blocks MAVProxy) |
| Comm Links | One manual UDP link on **14551** only — no link on 14550 |

In `~/.config/QGroundControl/QGroundControl.ini`:

```ini
[AutoConnect]
autoConnectUDP=false
```

---

## Network / NAT

```
Internet sources (uplinks)          Recipients (NAT clients)
  wlan0  ──┐                        uap0   → AP users 192.168.54.x
  eth1   ──┼── MASQUERADE ──►       eth0   → radio net 192.168.53.x (GW 192.168.53.1)
           └── FORWARD ───────────►
```

| Interface | Role |
|---|---|
| `wlan0` | Wi‑Fi internet uplink |
| `eth0` | Built-in radio — **static `192.168.53.1/24`**, no default route |
| `eth1` | **USB debug internet** — DHCP (`192.168.0.x`) |
| `uap0` | AP for clients (`192.168.54.1/24`) — receives internet via NAT |

**AP clients** — MAVLink broadcast on UDP **14550**, video **RTSP** `rtsp://192.168.54.1:8554/stream` (RTP H.264 from drone UDP **5600**, relayed via ffmpeg/MediaMTX). See [docs/AP_CLIENTS.md](docs/AP_CLIENTS.md). Check: `check-ap-stream.sh`.

Interface names are fixed at boot via **systemd `.link`** (MAC → `eth0`/`eth1`).  
**Reboot required** after first install. Boot service `gcs-network.service` re-applies static IP if needed.

```bash
sudo ./scripts/setup_network.sh
sudo reboot
check-network.sh
```

**Dev PC (Windows):** USB adapter `192.168.0.x` = debug internet (direct, not via GCS).  
Radio/debug Ethernet `192.168.53.x` → gateway **`192.168.53.1`** (GCS) — internet only through NAT on the GCS.

```bash
sudo ./setup_wifi_ap.sh    # AP + NAT rules
./scripts/check-nat.sh     # from repo (or check-nat.sh after sudo ./setup_autostart.sh)
sudo ./scripts/setup-nat.sh
```

### GNOME: toggle AP on/off

After `setup_wifi_ap.sh`:

- **Tray icon** in the top panel (`gcs-ap-tray`) — right-click: on/off, settings
- Terminal: `toggle-ap.sh`

Uses `drone-hotspot.service` (not GNOME Settings → Hotspot).

AP clients get gateway `192.168.54.1` via dnsmasq. `setup-nat.sh` also masquerades phone traffic from `192.168.54.0/24` out `eth0`, so phones can reach `192.168.53.x` devices even if ArduPilot/sonar do not have a route back to the AP subnet.

---

## Autostart (Winmate GCS)

```bash
# MAVProxy + widget (systemd user services, ordered startup)
./setup_autostart.sh

# Wi-Fi AP + hotspot boot service
sudo ./setup_wifi_ap.sh
```

**Boot after login** — MAVProxy and widget start **in parallel** (no waits between them):

1. `drone-hotspot.service` — Wi-Fi AP + `hostapd` (at boot)
2. `mavproxy-gcs.service` — MAVProxy when `hostapd` is up (`--force-connected` keeps it running before the drone link is up)
3. `mav-widget.service` — overlay immediately; telemetry connects when MAVProxy/drone are ready

Typical time to overlay: **under 1 s** after graphical session.

Install or update system scripts:

```bash
sudo ./setup_autostart.sh
sudo install -m 755 scripts/start_mavproxy.sh /usr/local/bin/start_mavproxy.sh
sudo install -m 755 scripts/wait_gcs_ready.sh /usr/local/bin/wait_gcs_ready.sh
systemctl --user restart mavproxy-gcs mav-widget
```

Useful commands:

```bash
systemctl --user status mavproxy-gcs mav-widget
mav-gcs-logs.sh -f                 # follow log files
tail -f ~/.local/state/mav-gcs/mav-widget.log
```

> **Logs:** On some systems `journalctl --user` returns `No journal files were found` — user journal is not persisted. Use `systemctl --user status` (shows recent lines), `mav-gcs-logs.sh`, or `journalctl -b | grep run_widget`.

---

## Dependencies

| Library | Purpose |
|---|---|
| `pymavlink` | MAVLink encode/decode (ArduPilot dialect) |
| `evdev` | Linux input events — sticks, buttons |
| `tkinter` | Overlay UI (stdlib) |

### requirements.txt

```
pymavlink>=2.4.40
evdev>=1.7.0
```

---

## Architecture

```
[Winmate GCS Joystick]
      │ /dev/input/eventX
      ▼
[widget.py + joystick_reader.py]   50 Hz RC override
      │ RC_CHANNELS_OVERRIDE (#70), 13 channels
      ▼
[widget.py]  udp:127.0.0.1:14552  (via MAVProxy)
[MAVProxy]    udp:127.0.0.1:14551  (QGC)
      │
      ▼
[ArduPilot / Pixhawk]  via radio link (192.168.53.1:14550)
      │ MAVLink telemetry
      ▼
[widget.py + mavlink_link.py]
      └── parse → DroneState → overlay UI
```

---

## License

MIT © 2026
