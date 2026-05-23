"""Winmate GCS Joystick configuration — layout verified manually."""

# Physical stick layout
STICK_MAP = {
    "left": {"x": "ABS_X", "y": "ABS_Y"},
    "right": {"x": "ABS_Z", "y": "ABS_RX"},
}

# Physical button layout
BUTTON_MAP = {
    "BTN_NORTH": "left top",
    "BTN_WEST": "left middle",
    "BTN_TL2": "left bottom",
    "BTN_C": "left side",
    "BTN_TL": "right top",
    "BTN_TR": "right bottom",
    "BTN_Z": "right side",
}

# Human-readable axis names
AXIS_LABELS = {
    "ABS_X": "left stick X",
    "ABS_Y": "left stick Y",
    "ABS_Z": "right stick X",
    "ABS_RX": "right stick Y",
}

# Axis mapping to ArduPilot RC channels
AXIS_MAP = {
    "roll": "ABS_X",
    "pitch": "ABS_Y",
    "yaw": "ABS_Z",
    "throttle": "ABS_RX",
}

# Default input device (None = auto-detect Winmate GCS Joystick)
INPUT_DEVICE = None
JOYSTICK_NAME = "Winmate GCS Joystick"

# MAVLink via MAVProxy output (telemetry only — separate port from QGC)
MAVLINK_URI = "udp:127.0.0.1:14552"
MAVPROXY_MASTER = "192.168.53.1:14550"
QGC_PORT = 14551
WIDGET_PORT = 14552

# Axes with inverted up/down (evdev value flipped before PWM)
AXIS_INVERT = {
    "ABS_Y": True,   # left stick Y (pitch)
    "ABS_RX": True,  # right stick Y (throttle)
}

# Send RC override through MAVProxy (same link as telemetry)
RC_MAVLINK_URI = None

# All stick + button channels (1-11)
RC_OVERRIDE_CHANNELS = 11

# RC channel assignment (channel -> role, evdev axis)
RC_CHANNEL_MAP = {
    1: ("roll", "ABS_X"),
    2: ("pitch", "ABS_Y"),
    3: ("throttle", "ABS_RX"),
    4: ("yaw", "ABS_Z"),
}

# Button -> RC channel (momentary switch: 1000 off / 2000 on)
RC_BUTTON_MAP = {
    5: "BTN_NORTH",
    6: "BTN_WEST",
    7: "BTN_TL2",
    8: "BTN_C",
    9: "BTN_TL",
    10: "BTN_TR",
    11: "BTN_Z",
}

BUTTON_PWM_OFF = 1000
BUTTON_PWM_ON = 2000
RC_IGNORE = 65535
RC_CHANNELS = 18

# UDP ports (legacy / direct)
ARDUPILOT_HOST = "192.168.1.10"
ARDUPILOT_PORT = 14550

# RC failsafe (neutral)
FAILSAFE_PWM = 1500
RC_RATE_HZ = 50
AXIS_CENTER = 1024
AXIS_MIN = 0
AXIS_MAX = 2047
