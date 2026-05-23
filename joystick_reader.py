"""Evdev joystick reader for the widget and RC override."""

from __future__ import annotations

import logging
import threading

from evdev import InputDevice, ecodes, list_devices

from config import AXIS_LABELS, AXIS_MAP, BUTTON_MAP, INPUT_DEVICE, JOYSTICK_NAME
from drone_state import SharedState

log = logging.getLogger(__name__)


def _code_by_name(table: dict, name: str) -> int:
    for code, val in table.items():
        if isinstance(val, list):
            if name in val:
                return code
        elif val == name:
            return code
    raise KeyError(name)


def _abs_code(name: str) -> int:
    return _code_by_name(ecodes.ABS, name)


def _btn_code(name: str) -> int:
    return _code_by_name(ecodes.BTN, name)


# Build reverse maps from config axis/button names
TRACKED_AXES = set(AXIS_MAP.values()) | set(AXIS_LABELS.keys())
TRACKED_BTNS = set(BUTTON_MAP.keys())


class JoystickReader:
    def __init__(self, state: SharedState, device_path: str | None = INPUT_DEVICE) -> None:
        self.state = state
        self.device_path = device_path
        self._dev: InputDevice | None = None
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._axis_codes = {_abs_code(name): name for name in TRACKED_AXES}
        self._btn_codes = {_btn_code(name): name for name in TRACKED_BTNS}

    @staticmethod
    def _is_gamepad(dev: InputDevice) -> bool:
        caps = dev.capabilities(verbose=False)
        has_abs = ecodes.EV_ABS in caps
        has_btn = ecodes.EV_KEY in caps and any(0x100 <= c <= 0x1FF for c in caps[ecodes.EV_KEY])
        return has_abs and has_btn

    @staticmethod
    def find_device(path: str | None = None) -> str:
        if path:
            try:
                dev = InputDevice(path)
                if JOYSTICK_NAME in dev.name or JoystickReader._is_gamepad(dev):
                    return path
            except (OSError, PermissionError) as exc:
                log.warning("Cannot open %s: %s", path, exc)

        for dev_path in list_devices():
            try:
                dev = InputDevice(dev_path)
                if JOYSTICK_NAME in dev.name:
                    return dev_path
            except (OSError, PermissionError):
                continue

        for dev_path in list_devices():
            try:
                dev = InputDevice(dev_path)
                if JoystickReader._is_gamepad(dev):
                    return dev_path
            except (OSError, PermissionError):
                continue

        raise RuntimeError(f"No joystick device found (looking for {JOYSTICK_NAME!r})")

    def start(self, device_path: str | None = None) -> None:
        path = self.find_device(device_path or self.device_path)
        self._dev = InputDevice(path)
        log.info("Joystick opened: %s (%s)", self._dev.name, path)
        self._seed_state()
        with self.state._lock:
            self.state.joystick_connected = True
            self.state.joystick_device = path
            self.state.rc_override_active = True
        self._stop.clear()
        self._thread = threading.Thread(target=self._read_loop, name="joystick", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._dev:
            self._dev.close()
        with self.state._lock:
            self.state.joystick_connected = False
            self.state.rc_override_active = False

    def _seed_state(self) -> None:
        assert self._dev is not None
        active = set(self._dev.active_keys())
        with self.state._lock:
            for code, name in self._axis_codes.items():
                try:
                    info = self._dev.absinfo(code)
                except (OSError, TypeError):
                    continue
                if info is not None:
                    self.state.axis_values[name] = info.value
            for code, name in self._btn_codes.items():
                self.state.button_pressed[name] = code in active
        log.info("Joystick state seeded: axes=%s", dict(self.state.axis_values))

    def _read_loop(self) -> None:
        assert self._dev is not None
        for event in self._dev.read_loop():
            if self._stop.is_set():
                break
            if event.type == ecodes.EV_ABS and event.code in self._axis_codes:
                name = self._axis_codes[event.code]
                with self.state._lock:
                    self.state.axis_values[name] = event.value
            elif event.type == ecodes.EV_KEY and event.code in self._btn_codes:
                name = self._btn_codes[event.code]
                with self.state._lock:
                    self.state.button_pressed[name] = bool(event.value)
