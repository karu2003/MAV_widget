"""MAVLink connection: telemetry parsing and RC override."""

from __future__ import annotations

import logging
import threading
import time

from pymavlink import mavutil

from config import (
    AXIS_CENTER,
    AXIS_INVERT,
    AXIS_MAX,
    BUTTON_PWM_OFF,
    BUTTON_PWM_ON,
    FAILSAFE_PWM,
    MAVLINK_URI,
    RC_BUTTON_MAP,
    RC_CHANNEL_MAP,
    RC_CHANNELS,
    RC_IGNORE,
    RC_MAVLINK_URI,
    RC_OVERRIDE_CHANNELS,
    RC_RATE_HZ,
)
from drone_state import SharedState

log = logging.getLogger(__name__)

FLIGHT_MODES = {
    0: "Stabilize",
    1: "Acro",
    2: "AltHold",
    3: "Auto",
    4: "Guided",
    5: "Loiter",
    6: "RTL",
    7: "Circle",
    9: "Land",
    11: "Drift",
    13: "Sport",
    14: "Flip",
    15: "AutoTune",
    16: "PosHold",
    17: "Brake",
    18: "Throw",
    19: "Avoid_ADSB",
    20: "Guided_NoGPS",
    21: "Smart_RTL",
    22: "FlowHold",
    23: "Follow",
    24: "ZigZag",
    25: "SystemID",
    26: "Heli_Autorotate",
    27: "Auto RTL",
}


def button_to_pwm(pressed: bool) -> int:
    return BUTTON_PWM_ON if pressed else BUTTON_PWM_OFF


def normalize_axis(value: int, axis_name: str) -> int:
    clamped = max(0, min(AXIS_MAX, value))
    if AXIS_INVERT.get(axis_name, False):
        clamped = AXIS_MAX - clamped
    return clamped


def build_rc_channels(axis_values: dict[str, int], button_pressed: dict[str, bool]) -> list[int]:
    channels = [RC_IGNORE] * RC_CHANNELS

    for ch, (role, axis_name) in RC_CHANNEL_MAP.items():
        raw = normalize_axis(axis_values.get(axis_name, AXIS_CENTER), axis_name)
        channels[ch - 1] = axis_to_pwm(raw, role)

    for ch, btn_name in RC_BUTTON_MAP.items():
        channels[ch - 1] = button_to_pwm(button_pressed.get(btn_name, False))

    return channels


def axis_to_pwm(value: int, channel: str) -> int:
    if channel == "throttle":
        return int(1000 + (value / AXIS_MAX) * 1000)
    return int(FAILSAFE_PWM + ((value - AXIS_CENTER) / AXIS_CENTER) * 500)


class MavlinkLink:
    def __init__(
        self,
        state: SharedState,
        uri: str = MAVLINK_URI,
        rc_uri: str | None = RC_MAVLINK_URI,
    ) -> None:
        self.state = state
        self.uri = uri
        self.rc_uri = rc_uri
        self._master: mavutil.mavfile | None = None
        self._rc_master: mavutil.mavfile | None = None
        self._target_system = 1
        self._target_component = mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1
        self._stop = threading.Event()
        self._rx_thread: threading.Thread | None = None
        self._tx_thread: threading.Thread | None = None

    def start(self) -> None:
        log.info("Connecting to MAVLink telemetry: %s", self.uri)
        self._master = mavutil.mavlink_connection(self.uri)
        self._master.wait_heartbeat(timeout=10)
        log.info(
            "Telemetry heartbeat (sys=%s comp=%s)",
            self._master.target_system,
            self._master.target_component,
        )
        self._target_system = self._master.target_system
        if self._master.target_component:
            self._target_component = self._master.target_component
        else:
            self._target_component = mavutil.mavlink.MAV_COMP_ID_AUTOPILOT1

        if self.rc_uri and self.rc_uri != self.uri:
            log.info("Connecting to RC override link: %s", self.rc_uri)
            self._rc_master = mavutil.mavlink_connection(self.rc_uri)

        log.info("RC override target sys=%s comp=%s", self._target_system, self._target_component)

        self.state.update_drone(connected=True, last_heartbeat=time.time())
        self._stop.clear()
        self._rx_thread = threading.Thread(target=self._rx_loop, name="mavlink-rx", daemon=True)
        self._tx_thread = threading.Thread(target=self._tx_loop, name="mavlink-tx", daemon=True)
        self._rx_thread.start()
        self._tx_thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._rc_master:
            self._rc_master.close()
            self._rc_master = None
        if self._master:
            self._master.close()
            self._master = None
        self.state.update_drone(connected=False)

    def _rx_loop(self) -> None:
        assert self._master is not None
        while not self._stop.is_set():
            msg = self._master.recv_match(blocking=True, timeout=1.0)
            if msg is None:
                continue
            self._handle_message(msg)

    def _handle_message(self, msg) -> None:
        msg_type = msg.get_type()
        if msg_type == "HEARTBEAT":
            src_sys = msg.get_srcSystem()
            src_comp = msg.get_srcComponent()
            if src_sys == self._target_system and msg.autopilot != mavutil.mavlink.MAV_AUTOPILOT_INVALID:
                self._target_component = src_comp
            base_mode = msg.base_mode
            custom_mode = msg.custom_mode
            armed = bool(base_mode & mavutil.mavlink.MAV_MODE_FLAG_SAFETY_ARMED)
            mode = FLIGHT_MODES.get(custom_mode, f"Mode({custom_mode})")
            self.state.update_drone(
                connected=True,
                last_heartbeat=time.time(),
                mode=mode,
                armed=armed,
                system_status=msg.system_status,
            )
        elif msg_type == "ATTITUDE":
            self.state.update_drone(
                roll=msg.roll,
                pitch=msg.pitch,
                yaw=msg.yaw,
            )
        elif msg_type == "SYS_STATUS":
            if msg.voltage_battery != 65535:
                self.state.update_drone(
                    battery_v=msg.voltage_battery / 1000.0,
                    battery_pct=msg.battery_remaining,
                )
        elif msg_type == "GPS_RAW_INT":
            self.state.update_drone(
                gps_fix=msg.fix_type,
                gps_sats=msg.satellites_visible,
                lat=msg.lat / 1e7,
                lon=msg.lon / 1e7,
                alt_m=msg.alt / 1000.0,
            )
        elif msg_type == "VFR_HUD":
            self.state.update_drone(
                groundspeed_m_s=msg.groundspeed,
                heading_deg=msg.heading,
                alt_m=msg.alt,
            )

    def _tx_loop(self) -> None:
        assert self._master is not None
        interval = 1.0 / RC_RATE_HZ
        while not self._stop.is_set():
            _, joy_ok, _, axis_values, button_pressed, rc_active = self.state.snapshot()
            if joy_ok and rc_active:
                channels = build_rc_channels(axis_values, button_pressed)
                self._send_rc_override(channels)
            time.sleep(interval)

    def _send_rc_override(self, channels: list[int]) -> None:
        link = self._rc_master or self._master
        if link is None:
            return
        padded = channels + [RC_IGNORE] * (RC_CHANNELS - len(channels))
        link.mav.rc_channels_override_send(
            self._target_system,
            self._target_component,
            *padded[:RC_OVERRIDE_CHANNELS],
        )
