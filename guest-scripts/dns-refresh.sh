#!/bin/sh
# DHCP/DNS refresh
ip link set eth0 down 2>/dev/null; ip link set eth0 up 2>/dev/null; killall udhcpc >/dev/null 2>&1; udhcpc -i eth0 -q -n -f -T 2 -t 5 >/dev/null 2>&1; printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' > /etc/resolv.conf; echo "[restore-net] DHCP + DNS refreshed"