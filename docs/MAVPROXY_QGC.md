# MAVProxy + QGroundControl (GCS setup)

Official docs:

- [MAVProxy startup options](https://ardupilot.org/mavproxy/docs/getting_started/starting.html) (`--master`, `--out`)
- [Telemetry forwarding](https://ardupilot.org/mavproxy/docs/getting_started/forwarding.html)
- [QGC General settings — AutoConnect UDP](https://docs.qgroundcontrol.com/master/en/qgc-user-guide/settings_view/general.html)

## How it should work (this project)

```
ArduPilot  --UDP-->  192.168.53.1:14550  (MAVProxy --master only)
                           |
                     MAVProxy
                     /    |    \
            127.0.0.1:14551  127.0.0.1:14552  broadcast 192.168.54.255:14550  udpin 192.168.54.1:14550
                 |              |
               QGC            widget
```

| Role | Port | Who binds |
|------|------|-----------|
| Drone → GCS | **14550** on `192.168.53.1` | **MAVProxy** (`udpin:192.168.53.1:14550`) |
| QGC telemetry | **14551** | QGC listens; MAVProxy `--out=127.0.0.1:14551` sends packets |
| Widget | **14552** | Widget listens via pymavlink; MAVProxy `--out=127.0.0.1:14552` |

From the [forwarding guide](https://ardupilot.org/mavproxy/docs/getting_started/forwarding.html):

```bash
mavproxy.py --master=/dev/ttyACM0 --baudrate 115200 --out 127.0.0.1:14550
```

Then the ground station **listens on that UDP port**. We use **14551** instead of 14550 so MAVProxy can own 14550 for the radio link.

## Why QGC does not see ArduPilot

### 1. QGC AutoConnect UDP on port 14550 (most common)

QGC **always** opens UDP **14550** when **Settings → General → AutoConnect to UDP** is enabled. That steals packets from MAVProxy’s master on the same machine.

`ss -ulnp` then shows:

```
QGroundControl  0.0.0.0:14550
python3         192.168.53.1:14550   # MAVProxy
```

MAVProxy log stays empty (`~/mav.tlog` size 0), QGC on 14551 gets nothing.

**Fix:**

1. QGC → **Settings (gear) → General**
2. Uncheck **AutoConnect to UDP devices**
3. **Comm Links**: one UDP link, port **14551** only (no 14550)
4. Restart QGC, then restart MAVProxy

Or in `~/.config/QGroundControl/QGroundControl.ini`:

```ini
[AutoConnect]
autoConnectUDP=false
```

### 2. Wrong QGC port

With our autostart, QGC must listen on **14551**, not 14550.

### 3. MAVProxy not linked to drone

Check:

```bash
ls -la ~/mav.tlog          # should grow when drone is on
pgrep -af mavproxy
ss -ulnp | grep 145
```

Test drone without QGC on 14550:

```bash
python3 -c "from pymavlink import mavutil; m=mavutil.mavlink_connection('udp:192.168.53.1:14550'); print(m.wait_heartbeat(timeout=5))"
```

## Restart sequence

```bash
pkill -f QGroundControl
pkill -f mavproxy.py

/usr/local/bin/autostart-gcs.sh    # or scripts/autostart-gcs.sh from repo

# QGC after MAVProxy
/usr/bin/QGroundControl &

systemctl --user restart mav-widget
```

## Reference command (matches scripts/start_mavproxy.sh)

```bash
mavproxy.py \
    --master=udpin:192.168.53.1:14550 \
    --out=udp:127.0.0.1:14550 \        # local QGC (AutoConnect UDP)
    --out=127.0.0.1:14551 \            # spare local link
    --out=127.0.0.1:14552 \            # MAV_Widget
    --out=udp:127.0.0.1:14545 \        # mav-ap-fanout feed → AP phones
    --nowait \
    --force-connected \
    --non-interactive
```

> **AP clients:** telemetry is delivered by `mav-ap-fanout.service`
> (`scripts/mav-ap-fanout.py`), which **unicasts** to every phone on the AP and
> owns `192.168.54.1:14550` for their uplink. We no longer use `udpbcast`:
> pymavlink latches its broadcast socket onto the first responder (the local
> QGC), so phones never received data. See
> [INSTALL_WINMATE.md](INSTALL_WINMATE.md) §4.
