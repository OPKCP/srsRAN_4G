#!/usr/bin/env python3
"""UDP echo-сервер для теста проброса порта 2152 (GTP-U) через Docker."""
import socket

PORT = int(__import__('os').environ.get('UDP_PORT', '2152'))
BIND = __import__('os').environ.get('UDP_BIND', '0.0.0.0')

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((BIND, PORT))
print(f"UDP echo server listening on {BIND}:{PORT}", flush=True)
s.settimeout(30)
try:
    while True:
        data, addr = s.recvfrom(1500)
        print(f"recv {len(data)} bytes from {addr}", flush=True)
        s.sendto(b'pong', addr)
except socket.timeout:
    print("timeout, exiting", flush=True)
