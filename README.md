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
- Displays a always-on-top telemetry overlay (link, mode, battery, GPS, attitude, joystick, buttons)
- Parses drone state from MAVLink (`HEARTBEAT`, `ATTITUDE`, `SYS_STATUS`, `GPS_RAW_INT`, `VFR_HUD`)

```
/dev/input/eventX  →  widget.py / joystick_reader.py  →  RC_CHANNELS_OVERRIDE (50 Hz)  →  MAVProxy  →  ArduPilot
ArduPilot :14550  →  widget.py (telemetry + RC)     direct
                 →  MAVProxy :14551                 →  QGC
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
├── scripts/
│   ├── run_widget.sh      # launch widget on local display
│   ├── autostart-gcs.sh   # start MAVProxy after login
│   ├── start-drone-hotspot.sh
│   └── stop-drone-hotspot.sh
├── systemd/
│   ├── mav-widget.service
│   └── drone-hotspot.service
├── setup_autostart.sh     # install widget user service
└── setup_wifi_ap.sh       # install Wi-Fi AP boot service
```

---

## Components

### widget.py

Main application. Connects directly to the drone on `udp:192.168.53.1:14550` for telemetry and RC override. QGC uses port **14551** via MAVProxy — separate port, no conflict.

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
python3 widget.py --geometry +20+20 -v
python3 widget.py --no-joystick          # telemetry only, no RC override
python3 widget.py --device /dev/input/event9
```

### MAVProxy (required for telemetry and RC)

```bash
python3 ~/.local/bin/mavproxy.py \
    --master=udp:192.168.53.1:14550 \
    --out=udp:127.0.0.1:14551 \
    --out=udp:192.168.54.255:14550 \
    --daemon
```

The widget connects directly to `udp:192.168.53.1:14550`. **QGC must listen on UDP port 14551** (not 14550). Disable the joystick in QGC — RC control goes through this widget.

### QGC connection settings

| Setting | Value |
|---|---|
| Type | UDP |
| Port | **14551** (Listen) |
| Do NOT use | port 14550 in QGC (conflicts with drone link) |

---

## Autostart (Winmate GCS)

```bash
# Widget overlay (systemd user service)
./setup_autostart.sh

# Wi-Fi AP + hotspot boot service
sudo ./setup_wifi_ap.sh
```

After login:

- `mav-widget.service` — telemetry overlay + joystick RC
- `autostart-gcs.sh` — MAVProxy to the drone radio link
- `drone-hotspot.service` — Wi-Fi AP (`MantaAP`, 192.168.54.1/24)

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
[widget.py]  udp:192.168.53.1:14550  (telemetry + RC override, 11 ch)
[MAVProxy]    udp:127.0.0.1:14551     (QGC listen)
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
