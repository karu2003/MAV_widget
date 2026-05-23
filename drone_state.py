"""Shared drone telemetry state for the widget."""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field


@dataclass
class DroneState:
    connected: bool = False
    last_heartbeat: float = 0.0
    mode: str = "---"
    armed: bool = False
    system_status: int = 0

    roll: float = 0.0
    pitch: float = 0.0
    yaw: float = 0.0

    battery_v: float = 0.0
    battery_pct: int = -1

    gps_fix: int = 0
    gps_sats: int = 0
    lat: float = 0.0
    lon: float = 0.0
    alt_m: float = 0.0

    groundspeed_m_s: float = 0.0
    heading_deg: int = 0

    def age_s(self) -> float:
        if not self.last_heartbeat:
            return float("inf")
        return time.time() - self.last_heartbeat

    def is_stale(self, timeout_s: float = 3.0) -> bool:
        return self.age_s() > timeout_s


@dataclass
class SharedState:
    drone: DroneState = field(default_factory=DroneState)
    joystick_connected: bool = False
    joystick_device: str = ""
    axis_values: dict[str, int] = field(default_factory=dict)
    button_pressed: dict[str, bool] = field(default_factory=dict)
    rc_override_active: bool = False
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    def update_drone(self, **kwargs) -> None:
        with self._lock:
            for key, value in kwargs.items():
                setattr(self.drone, key, value)

    def snapshot(self) -> tuple[DroneState, bool, str, dict[str, int], dict[str, bool], bool]:
        with self._lock:
            return (
                DroneState(**self.drone.__dict__),
                self.joystick_connected,
                self.joystick_device,
                dict(self.axis_values),
                dict(self.button_pressed),
                self.rc_override_active,
            )
