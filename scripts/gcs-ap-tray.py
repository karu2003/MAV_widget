#!/usr/bin/env python3
"""GCS Wi-Fi AP — system tray icon and settings window (Ayatana AppIndicator)."""

from __future__ import annotations

import argparse
import fcntl
import os
import subprocess
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import AyatanaAppIndicator3, GLib, Gtk  # noqa: E402

APP_ID = "gcs-wifi-ap"
TOGGLE = os.environ.get("GCS_AP_TOGGLE", "/usr/local/bin/toggle-ap.sh")
ICON_ON = os.environ.get(
    "GCS_AP_ICON_ON",
    "/usr/local/share/icons/hicolor/48x48/apps/gcs-ap-on.png",
)
ICON_OFF = os.environ.get(
    "GCS_AP_ICON_OFF",
    "/usr/local/share/icons/hicolor/48x48/apps/gcs-ap-off.png",
)
AP_IP = "192.168.54.1"
HOSTAPD_CONF = os.environ.get("HOSTAPD_CONF", "/etc/hostapd/drone-hotspot.conf")
POLL_SEC = 5
_LOCK_FD: int | None = None


def _runtime_dir() -> str:
    uid = os.getuid()
    return os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{uid}")


def acquire_tray_lock() -> None:
    """Only one tray icon process (systemd + manual start must not duplicate)."""
    global _LOCK_FD
    lock_path = os.path.join(_runtime_dir(), "gcs-ap-tray.lock")
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        sys.exit(0)
    os.ftruncate(fd, 0)
    os.write(fd, str(os.getpid()).encode())
    _LOCK_FD = fd


def read_ssid() -> str:
    try:
        with open(HOSTAPD_CONF, encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("ssid="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return "AP"


def ap_running() -> bool:
    hostapd = subprocess.run(
        ["systemctl", "is-active", "--quiet", "hostapd"],
        check=False,
    )
    uap0 = subprocess.run(["ip", "link", "show", "uap0"], check=False)
    return hostapd.returncode == 0 and uap0.returncode == 0


def run_toggle() -> None:
    if os.path.isfile(TOGGLE) and os.access(TOGGLE, os.X_OK):
        subprocess.Popen([TOGGLE], start_new_session=True)


class ApSettingsWindow(Gtk.Window):
    def __init__(self, standalone: bool = False) -> None:
        super().__init__(title="GCS Wi-Fi AP")
        self.set_default_size(420, 220)
        self.set_border_width(16)
        self.set_position(Gtk.WindowPosition.CENTER)

        ssid = read_ssid()
        running = ap_running()

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.add(box)

        title = Gtk.Label()
        title.set_markup(f"<b>Wi‑Fi access point</b>\n<span size='small'>SSID: {ssid}</span>")
        title.set_xalign(0)
        box.pack_start(title, False, False, 0)

        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        box.pack_start(row, False, False, 0)

        self.switch = Gtk.Switch()
        self.switch.set_active(running)
        self.switch.set_sensitive(True)
        self.switch.connect("notify::active", self._on_switch)

        label = Gtk.Label(label="Hotspot (CaimanHS AP)")
        label.set_xalign(0)
        label.set_hexpand(True)
        row.pack_start(label, True, True, 0)
        row.pack_start(self.switch, False, False, 0)

        self.status = Gtk.Label()
        self.status.set_xalign(0)
        box.pack_start(self.status, False, False, 0)

        hint = Gtk.Label(
            label=(
                f"Phone clients: connect to {ssid}, IP {AP_IP}\n"
                "MAVLink UDP 14550 · RTSP rtsp://192.168.54.1:8554/stream"
            )
        )
        hint.set_xalign(0)
        hint.set_line_wrap(True)
        hint.get_style_context().add_class("dim-label")
        box.pack_start(hint, True, True, 0)

        close_btn = Gtk.Button(label="Close")
        close_btn.connect("clicked", lambda *_: self.close())
        close_btn.set_halign(Gtk.Align.END)
        box.pack_start(close_btn, False, False, 0)

        self._refresh_status()
        if standalone:
            self.connect("destroy", Gtk.main_quit)

    def _refresh_status(self) -> None:
        if ap_running():
            self.status.set_markup(
                f"<span foreground='#16a34a'>● ON</span> — {read_ssid()} at {AP_IP}"
            )
        else:
            self.status.set_markup("<span foreground='#dc2626'>● OFF</span>")

    def _on_switch(self, widget: Gtk.Switch, _pspec) -> None:
        want_on = widget.get_active()
        if want_on == ap_running():
            return
        widget.set_sensitive(False)
        run_toggle()
        GLib.timeout_add(2000, self._sync_switch)

    def _sync_switch(self) -> bool:
        running = ap_running()
        self.switch.set_sensitive(True)
        self.switch.set_active(running)
        self._refresh_status()
        return False


class ApTray:
    def __init__(self) -> None:
        self.ssid = read_ssid()
        self.indicator = AyatanaAppIndicator3.Indicator.new(
            APP_ID,
            "network-wireless",
            AyatanaAppIndicator3.IndicatorCategory.SYSTEM_SERVICES,
        )
        self.indicator.set_status(AyatanaAppIndicator3.IndicatorStatus.ACTIVE)
        self.indicator.set_title("GCS Wi-Fi AP")
        self.menu = Gtk.Menu()
        self._build_menu()
        self.indicator.set_menu(self.menu)
        self._update_icon()
        GLib.timeout_add_seconds(POLL_SEC, self._poll)

    def _build_menu(self) -> None:
        self.status_item = Gtk.MenuItem(label="Status…")
        self.status_item.set_sensitive(False)
        self.menu.append(self.status_item)

        self.menu.append(Gtk.SeparatorMenuItem())

        turn_on = Gtk.MenuItem(label="Turn AP on")
        turn_on.connect("activate", lambda *_: self._turn_on())
        self.menu.append(turn_on)
        self.turn_on_item = turn_on

        turn_off = Gtk.MenuItem(label="Turn AP off")
        turn_off.connect("activate", lambda *_: self._turn_off())
        self.menu.append(turn_off)
        self.turn_off_item = turn_off

        toggle = Gtk.MenuItem(label="Toggle AP")
        toggle.connect("activate", lambda *_: self._toggle())
        self.menu.append(toggle)

        self.menu.append(Gtk.SeparatorMenuItem())

        wifi = Gtk.MenuItem(label="Reconnect Wi‑Fi client (wlan0)")
        wifi.connect("activate", lambda *_: self._reconnect_wifi())
        self.menu.append(wifi)

        self.menu.append(Gtk.SeparatorMenuItem())

        settings = Gtk.MenuItem(label="Settings…")
        settings.connect("activate", lambda *_: open_settings_window())
        self.menu.append(settings)

        quit_item = Gtk.MenuItem(label="Quit tray icon")
        quit_item.connect("activate", lambda *_: Gtk.main_quit())
        self.menu.append(quit_item)

        self.menu.show_all()

    def _turn_on(self) -> None:
        if not ap_running():
            run_toggle()

    def _turn_off(self) -> None:
        if ap_running():
            run_toggle()

    def _toggle(self) -> None:
        run_toggle()

    def _reconnect_wifi(self) -> None:
        restore = os.environ.get(
            "GCS_RESTORE_WLAN", "/usr/local/bin/restore-wlan-client.sh"
        )
        if os.path.isfile(restore):
            subprocess.Popen(
                ["sudo", restore, "--recover"],
                start_new_session=True,
            )

    def _update_icon(self) -> None:
        running = ap_running()
        path = ICON_ON if running else ICON_OFF
        label = f"GCS AP {'ON' if running else 'OFF'}"
        if os.path.isfile(path):
            self.indicator.set_icon_full(path, label)
        else:
            self.indicator.set_icon(
                "network-wireless" if running else "network-wireless-offline",
            )
        state = "ON" if running else "OFF"
        self.status_item.set_label(f"{state}: {self.ssid}  ({AP_IP})")
        self.turn_on_item.set_sensitive(not running)
        self.turn_off_item.set_sensitive(running)

    def _poll(self) -> bool:
        self._update_icon()
        return True


def open_settings_window(standalone: bool = False) -> None:
    win = ApSettingsWindow(standalone=standalone)
    win.show_all()
    win.present()


def run_tray() -> None:
    acquire_tray_lock()
    ApTray()
    Gtk.main()


def main() -> int:
    parser = argparse.ArgumentParser(description="GCS Wi-Fi AP tray / settings")
    parser.add_argument(
        "--settings",
        action="store_true",
        help="Open settings window (also in app menu / Settings category)",
    )
    args = parser.parse_args()

    if args.settings:
        open_settings_window(standalone=True)
        Gtk.main()
    else:
        run_tray()
    return 0


if __name__ == "__main__":
    sys.exit(main())
