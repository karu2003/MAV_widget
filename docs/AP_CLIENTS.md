# Клиенты Wi‑Fi AP (MAVLink + видео)

Сеть **CaimanHS**, шлюз **192.168.54.1**, DHCP **192.168.54.10–100**.

## MAVLink (MAVProxy)

Телеметрия уходит **широковещательно** на подсеть AP:

```text
--out=udpbcast:192.168.54.255:14550
```

Команды с телефона/планшета принимаются на GCS:

```text
--out=udpin:192.168.54.1:14550
```

После включения AP MAVProxy перезапускается автоматически (`restart-ap-streaming.sh`).

### QGroundControl на клиенте AP

1. Подключиться к Wi‑Fi **CaimanHS**.
2. **Comm Links** → UDP, порт **14550**, режим **Listen** (или адрес **192.168.54.1:14550**).
3. На самом GCS в QGC отключить **AutoConnect UDP** на 14550 (см. [MAVPROXY_QGC.md](MAVPROXY_QGC.md)).

Проверка на GCS:

```bash
check-ap-stream.sh
```

## Видео (RTSP)

По умолчанию GCS слушает **H.264 по UDP 5600** (как у QGC/companion) и отдаёт клиентам AP:

```text
rtsp://192.168.54.1:8554/stream
```

Настройка: `/etc/default/gcs-ap-streaming`

| Переменная | Значение по умолчанию |
|------------|------------------------|
| `VIDEO_MODE` | `udp` |
| `VIDEO_UDP_PORT` | `5600` |
| `VIDEO_MODE=v4l2` | локальная камера `/dev/video0` |
| `VIDEO_MODE=test` | тестовая картинка (отладка) |

Сервис:

```bash
sudo systemctl enable --now gcs-video-rtsp
sudo journalctl -u gcs-video-rtsp -f
```

### QGC — видео

**Settings → Video** → RTSP URL:

`rtsp://192.168.54.1:8554/stream`

VLC на телефоне: тот же URL.

## Порты

| Сервис | Порт | Интерфейс |
|--------|------|-----------|
| MAVLink broadcast | 14550/udp | 192.168.54.255 |
| MAVLink uplink | 14550/udp | 192.168.54.1 |
| RTSP | 8554/tcp | 192.168.54.1 |
| Видео вход (UDP) | 5600/udp | 0.0.0.0 (с дрона/companion) |

Интернет для клиентов AP — NAT (`setup-nat.sh`). Прямой доступ к радиосети дрона **192.168.53.0/24** через `uap0 ↔ eth0`.
