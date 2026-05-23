#!/usr/bin/env python3
"""MAVLink telemetry overlay widget for Winmate GCS."""

from __future__ import annotations

import argparse
import logging
import math
import signal
import sys
import tkinter as tk
from tkinter import font as tkfont

from config import BUTTON_MAP, INPUT_DEVICE, MAVLINK_URI
from drone_state import SharedState
from joystick_reader import JoystickReader
from mavlink_link import MavlinkLink

log = logging.getLogger(__name__)

BG = "#1a1a2e"
PANEL = "#16213e"
FG = "#e0e0e0"
ACCENT = "#0f3460"
OK = "#2ecc71"
WARN = "#f39c12"
ERR = "#e74c3c"
MUTED = "#888888"

WIDGET_WIDTH = 210
WIDGET_HEIGHT = 280
WIDGET_MARGIN = 20


def _right_geometry(root: tk.Tk) -> str:
    x = max(WIDGET_MARGIN, root.winfo_screenwidth() - WIDGET_WIDTH - WIDGET_MARGIN)
    return f"+{x}+{WIDGET_MARGIN}"

class TelemetryWidget:
    REFRESH_MS = 200

    def __init__(self, root: tk.Tk, state: SharedState, *, rc_via_mavproxy: bool = False) -> None:
        self.root = root
        self.state = state
        self.rc_via_mavproxy = rc_via_mavproxy
        self.root.title("MAV Widget")
        self.root.configure(bg=BG)
        self.root.attributes("-topmost", True)
        self.root.resizable(False, False)

        self.title_font = tkfont.Font(family="DejaVu Sans Mono", size=11, weight="bold")
        self.label_font = tkfont.Font(family="DejaVu Sans Mono", size=10)
        self.value_font = tkfont.Font(family="DejaVu Sans Mono", size=10, weight="bold")

        frame = tk.Frame(root, bg=PANEL, padx=12, pady=10, highlightbackground=ACCENT, highlightthickness=1)
        frame.pack(fill=tk.BOTH, expand=True)

        self.status_label = self._row(frame, "LINK", "---", 0)
        self.mode_label = self._row(frame, "MODE", "---", 1)
        self.battery_label = self._row(frame, "BATT", "---", 2)
        self.gps_label = self._row(frame, "GPS", "---", 3)
        self.alt_label = self._row(frame, "ALT", "---", 4)
        self.speed_label = self._row(frame, "SPD", "---", 5)
        self.att_label = self._row(frame, "ATT", "---", 6)
        self.joy_label = self._row(frame, "JOY", "---", 7)
        self.btn_label = self._row(frame, "BTN", "---", 8)

        self.root.after(self.REFRESH_MS, self._refresh)

    def _row(self, parent: tk.Frame, title: str, value: str, row: int) -> tk.Label:
        tk.Label(parent, text=title, font=self.label_font, fg=MUTED, bg=PANEL, width=5, anchor="w").grid(
            row=row, column=0, sticky="w", pady=2
        )
        lbl = tk.Label(parent, text=value, font=self.value_font, fg=FG, bg=PANEL, anchor="w")
        lbl.grid(row=row, column=1, sticky="w", padx=(8, 0), pady=2)
        return lbl

    def _refresh(self) -> None:
        drone, joy_ok, joy_path, axes, buttons, rc_active = self.state.snapshot()

        if drone.connected and not drone.is_stale():
            link_text = "OK"
            link_color = OK
        elif drone.connected:
            link_text = "STALE"
            link_color = WARN
        else:
            link_text = "NO LINK"
            link_color = ERR

        self.status_label.configure(text=link_text, fg=link_color)

        mode_text = drone.mode
        if drone.armed:
            mode_text += "  ARMED"
        self.mode_label.configure(text=mode_text, fg=ERR if drone.armed else FG)

        if drone.battery_pct >= 0:
            batt_text = f"{drone.battery_v:.1f}V  {drone.battery_pct}%"
            batt_color = WARN if drone.battery_pct < 30 else FG
        else:
            batt_text = "---"
            batt_color = MUTED
        self.battery_label.configure(text=batt_text, fg=batt_color)

        fix_names = {0: "NO FIX", 1: "NO FIX", 2: "2D", 3: "3D", 4: "DGPS", 5: "RTK"}
        fix = fix_names.get(drone.gps_fix, str(drone.gps_fix))
        self.gps_label.configure(text=f"{fix}  {drone.gps_sats} sats", fg=FG if drone.gps_fix >= 3 else WARN)

        self.alt_label.configure(text=f"{drone.alt_m:.1f} m", fg=FG)
        self.speed_label.configure(text=f"{drone.groundspeed_m_s:.1f} m/s  hdg {drone.heading_deg}", fg=FG)

        r = math.degrees(drone.roll)
        p = math.degrees(drone.pitch)
        y = math.degrees(drone.yaw)
        self.att_label.configure(text=f"R{r:+.0f} P{p:+.0f} Y{y:+.0f}", fg=FG)

        if self.rc_via_mavproxy:
            joy_text = "MAVProxy"
            joy_color = OK
        elif joy_ok:
            rc_tag = "RC ON" if rc_active else "RC OFF"
            joy_text = f"{rc_tag}  {joy_path.split('/')[-1]}"
            joy_color = OK
        else:
            joy_text = "disconnected"
            joy_color = ERR
        self.joy_label.configure(text=joy_text, fg=joy_color)

        pressed = [BUTTON_MAP.get(k, k) for k, v in buttons.items() if v]
        btn_text = ", ".join(pressed) if pressed else "---"
        self.btn_label.configure(text=btn_text, fg=WARN if pressed else MUTED)

        self.root.after(self.REFRESH_MS, self._refresh)


def main() -> None:
    parser = argparse.ArgumentParser(description="MAVLink telemetry overlay widget.")
    parser.add_argument("--mavlink", default=MAVLINK_URI, help="MAVLink URI (default: MAVProxy output)")
    parser.add_argument("--device", default=None, help="Joystick evdev path (default: auto-detect Winmate)")
    parser.add_argument("--no-joystick", action="store_true", help="Telemetry only, no RC override")
    parser.add_argument(
        "--geometry",
        default=None,
        help="Window position, e.g. +20+20 (default: top-right of screen)",
    )
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    state = SharedState()
    mavlink = MavlinkLink(state, uri=args.mavlink)
    joystick = JoystickReader(state, device_path=args.device)

    mavlink.start()

    if not args.no_joystick:
        try:
            joystick.start(args.device)
        except Exception as exc:
            log.error("Joystick failed: %s", exc)

    root = tk.Tk()
    position = args.geometry if args.geometry else _right_geometry(root)
    root.geometry(f"{WIDGET_WIDTH}x{WIDGET_HEIGHT}{position}")
    widget = TelemetryWidget(root, state, rc_via_mavproxy=args.no_joystick)

    def shutdown(_signum=None, _frame=None) -> None:
        log.info("Shutting down...")
        joystick.stop()
        mavlink.stop()
        root.quit()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)
    root.protocol("WM_DELETE_WINDOW", shutdown)

    try:
        root.mainloop()
    finally:
        shutdown()


if __name__ == "__main__":
    main()
