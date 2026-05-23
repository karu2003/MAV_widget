#!/usr/bin/env python3
"""Interactive probe for external input devices (joystick, buttons, axes)."""

from __future__ import annotations

import argparse
import sys

from evdev import InputDevice, categorize, ecodes, list_devices

from config import AXIS_LABELS, BUTTON_MAP


def _label(names) -> str:
    if isinstance(names, (list, tuple)):
        return str(names[0])
    return str(names)


def _code_name(code_type: str, code: int) -> str:
    if code_type == "EV_KEY" and 0x100 <= code <= 0x1FF:
        name = ecodes.BTN.get(code)
        if name is not None:
            return _label(name)
    table = {
        "EV_KEY": ecodes.KEY,
        "EV_ABS": ecodes.ABS,
        "EV_REL": ecodes.REL,
    }.get(code_type, {})
    name = table.get(code)
    if name is not None:
        return _label(name)
    return f"{code_type}_{code}"


def _friendly_name(code_type: str, code: int) -> str:
    ev_name = _code_name(code_type, code)
    if code_type == "EV_KEY":
        return BUTTON_MAP.get(ev_name, ev_name)
    if code_type == "EV_ABS":
        return AXIS_LABELS.get(ev_name, ev_name)
    return ev_name


def _axis_pct(value: int, center: int = 1024, half_range: int = 1024) -> str:
    pct = round((value - center) / half_range * 100)
    return f"{pct:+d}%"


def _is_joystick(dev: InputDevice) -> bool:
    caps = dev.capabilities(verbose=False)
    has_abs = ecodes.EV_ABS in caps
    has_btn = ecodes.EV_KEY in caps and any(0x100 <= c <= 0x1FF for c in caps[ecodes.EV_KEY])
    return has_abs and has_btn


def list_devices_info() -> list[tuple[str, InputDevice]]:
    result: list[tuple[str, InputDevice]] = []
    for path in list_devices():
        try:
            dev = InputDevice(path)
            result.append((path, dev))
        except (OSError, PermissionError):
            continue
    return result


def print_device_list() -> None:
    devices = list_devices_info()
    if not devices:
        print("No input devices found.")
        return

    print("Available devices:\n")
    for path, dev in devices:
        kind = "joystick" if _is_joystick(dev) else "other"
        print(f"  {path:22s}  [{kind:8s}]  {dev.name}")


def pick_device(path: str | None) -> InputDevice:
    devices = list_devices_info()
    if not devices:
        sys.exit("Error: no input devices found.")

    if path:
        for dev_path, dev in devices:
            if dev_path == path:
                return dev
        sys.exit(f"Error: device {path!r} not found. Run with --list.")

    joysticks = [(p, d) for p, d in devices if _is_joystick(d)]
    if len(joysticks) == 1:
        _, dev = joysticks[0]
        return dev
    if len(joysticks) > 1:
        print("Multiple joysticks found, specify --device:\n")
        for p, d in joysticks:
            print(f"  {p}  {d.name}")
        sys.exit(1)

    print("No joystick auto-detected. Available devices:\n")
    for p, d in devices:
        print(f"  {p}  {d.name}")
    sys.exit("Specify a device path: --device /dev/input/eventX")


def _cap_list(caps: dict, ev_name: str) -> list:
    for key, items in caps.items():
        if isinstance(key, tuple) and key[0] == ev_name:
            return items
    return caps.get(ev_name, [])


def print_capabilities(dev: InputDevice) -> None:
    caps = dev.capabilities(verbose=True)

    print(f"\n=== {dev.name} ===")
    print(f"Path:   {dev.path}")
    print(f"Phys:   {dev.phys or '—'}")
    print(f"Uniq:   {dev.uniq or '—'}")

    abs_list = _cap_list(caps, "EV_ABS")
    if abs_list:
        print(f"\nAxes ({len(abs_list)}):")
        for names, info in abs_list:
            label = _label(names)
            friendly = AXIS_LABELS.get(label, "")
            suffix = f"  ({friendly})" if friendly else ""
            print(f"  {label:14s}  min={info.min:5d}  max={info.max:5d}  value={info.value:5d}{suffix}")

    key_list = _cap_list(caps, "EV_KEY")
    btn_codes = [item for item in key_list if isinstance(item, tuple) and item[1] >= 0x100]
    if btn_codes:
        print(f"\nButtons ({len(btn_codes)}):")
        for names, _code in btn_codes:
            ev_name = _label(names)
            friendly = BUTTON_MAP.get(ev_name, "")
            suffix = f"  ({friendly})" if friendly else ""
            print(f"  {ev_name}{suffix}")


def probe(dev: InputDevice, axis_deadzone: int = 50) -> None:
    print_capabilities(dev)

    print("\n--- Live probe ---")
    print("Move sticks and press buttons. Ctrl+C to exit.\n")

    last_axis: dict[int, int] = {}

    try:
        for event in dev.read_loop():
            if event.type == ecodes.EV_KEY:
                key_event = categorize(event)
                action = "pressed" if key_event.keystate == key_event.key_down else "released"
                ev_name = _code_name("EV_KEY", event.code)
                friendly = _friendly_name("EV_KEY", event.code)
                label = f"{friendly} ({ev_name})" if friendly != ev_name else ev_name
                print(f"[KEY]   {label:30s}  {action}", flush=True)

            elif event.type == ecodes.EV_ABS:
                prev = last_axis.get(event.code)
                if prev is not None and abs(event.value - prev) < axis_deadzone:
                    continue
                last_axis[event.code] = event.value
                ev_name = _code_name("EV_ABS", event.code)
                friendly = _friendly_name("EV_ABS", event.code)
                label = f"{friendly} ({ev_name})" if friendly != ev_name else ev_name
                pct = _axis_pct(event.value)
                print(f"[AXIS]  {label:30s}  value={event.value:4d}  ({pct})", flush=True)

            elif event.type == ecodes.EV_REL:
                name = _code_name("EV_REL", event.code)
                print(f"[REL]   {name:20s}  value={event.value}", flush=True)

    except KeyboardInterrupt:
        print("\nProbe finished.")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Probe buttons and axes of an external input device (evdev)."
    )
    parser.add_argument(
        "--device", "-d",
        help="Device path, e.g. /dev/input/event5",
    )
    parser.add_argument(
        "--list", "-l",
        action="store_true",
        help="List devices and exit",
    )
    parser.add_argument(
        "--deadzone",
        type=int,
        default=50,
        help="Minimum axis change to report (default: 50)",
    )
    args = parser.parse_args()

    if args.list:
        print_device_list()
        return

    dev = pick_device(args.device)
    probe(dev, axis_deadzone=args.deadzone)


if __name__ == "__main__":
    main()
