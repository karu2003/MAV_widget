#!/usr/bin/env python3
"""Unicast MAVLink fan-out to Wi-Fi AP clients (phones).

Why not udpbcast?
  pymavlink's ``udpbcast`` output stops broadcasting as soon as it receives a
  single reply: it latches onto that sender (``connect()``) and turns
  broadcast off. On the GCS the local QGroundControl (0.0.0.0:14550) answers
  first, so the socket locks onto 127.0.0.1 and nothing ever reaches the
  phones. Wi-Fi broadcast is also frequently dropped by Android. Per-client
  unicast is what the working (master) setup used and is far more reliable.

Data path
  MAVProxy  --out=udp:127.0.0.1:<FEED_PORT>  <-->  this relay  <-->  phones
  - telemetry from MAVProxy (FEED socket) is unicast to every AP client
    (DHCP leases + clients that have talked to us) on <CLIENT_PORT>
  - packets from phones (AP socket, bound to AP_IP:<CLIENT_PORT>) are sent
    back to MAVProxy so command / RC uplink keeps working
"""

import os
import select
import socket
import time

AP_IP = os.environ.get("AP_IP", "192.168.54.1")
CLIENT_PORT = int(os.environ.get("MAV_AP_IN_PORT", "14550"))
FEED_PORT = int(os.environ.get("MAV_AP_FANOUT_PORT", "14545"))
LEASES_FILE = os.environ.get("DNSMASQ_LEASES", "/var/lib/misc/dnsmasq.leases")
LEASE_REFRESH = 3.0          # seconds between lease-file reads
CLIENT_TTL = 30.0            # forget learned clients after this idle time


def read_lease_ips():
    """Return the set of IPs currently leased on the AP subnet."""
    ips = set()
    net_prefix = AP_IP.rsplit(".", 1)[0] + "."
    try:
        with open(LEASES_FILE, "r") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 3 and parts[2].startswith(net_prefix):
                    ips.add(parts[2])
    except FileNotFoundError:
        pass
    except OSError:
        pass
    ips.discard(AP_IP)
    return ips


def bind_ap_socket():
    """Bind the AP-side socket, retrying until AP_IP exists."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    while True:
        try:
            sock.bind((AP_IP, CLIENT_PORT))
            return sock
        except OSError as exc:
            print(f"[fanout] waiting for {AP_IP}:{CLIENT_PORT} ({exc})", flush=True)
            time.sleep(2)


def main():
    feed = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    feed.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    feed.bind(("127.0.0.1", FEED_PORT))

    ap = bind_ap_socket()

    print(f"[fanout] feed 127.0.0.1:{FEED_PORT} <-> AP {AP_IP}:{CLIENT_PORT} "
          f"-> clients :{CLIENT_PORT}", flush=True)

    mav_addr = None            # MAVProxy's source address (for uplink return)
    learned = {}               # (ip, port) -> last_seen
    lease_ips = set()
    last_lease = 0.0

    while True:
        now = time.time()
        if now - last_lease >= LEASE_REFRESH:
            lease_ips = read_lease_ips()
            last_lease = now

        # drop stale learned clients
        for key in [k for k, t in learned.items() if now - t > CLIENT_TTL]:
            del learned[key]

        rlist, _, _ = select.select([feed, ap], [], [], 1.0)

        for sock in rlist:
            try:
                data, src = sock.recvfrom(65535)
            except OSError:
                continue
            if not data:
                continue

            if sock is feed:
                # telemetry from MAVProxy -> every AP client
                mav_addr = src
                targets = set(learned.keys())
                learned_ips = {ip for ip, _ in learned}
                for ip in lease_ips:
                    if ip not in learned_ips:
                        targets.add((ip, CLIENT_PORT))
                for dst in targets:
                    try:
                        ap.sendto(data, dst)
                    except OSError:
                        pass
            else:
                # packet from a phone -> remember it, forward uplink to MAVProxy
                learned[src] = now
                if mav_addr is not None:
                    try:
                        feed.sendto(data, mav_addr)
                    except OSError:
                        pass


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
