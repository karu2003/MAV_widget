# Secrets and credentials

This repository must **not** contain passwords, pre-shared keys, or API tokens.

## Where credentials live (on the GCS, not in git)

| Item | Location on device |
|------|-------------------|
| Wi‑Fi AP (SSID + WPA) | `/etc/hostapd/drone-hotspot.conf` (installed outside this repo) |
| User session / sudo | system configuration (`/etc/sudoers.d/`, not copied into the repo) |

Scripts read the AP SSID at runtime from `/etc/hostapd/drone-hotspot.conf` (see `toggle-ap.sh`). Do not copy that file into the project tree.

## What is safe in the repo

- IP addresses and port numbers (`192.168.53.1`, `192.168.54.1`, MAVLink ports)
- AP **SSID name** in docs (e.g. CaimanHS) — not a secret
- Ethernet MAC addresses in `.link` / NetworkManager profiles (hardware IDs)

## Before committing

```bash
rg -i 'password|passphrase|psk=|wpa_passphrase|secret|api[_-]?key|token' .
```

If you add a hostapd template, use a placeholder only, e.g. `wpa_passphrase=__SET_ON_DEVICE__`.
