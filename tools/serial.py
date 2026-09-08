#!/usr/bin/env python3
"""Send lines to a unix socket (QEMU serial or monitor) and print what comes back.
usage: sock.py <socket> <settle_seconds> <line1> [line2 ...]   ('SLEEP:n' pauses n seconds)"""
import socket, sys, time
path, settle, lines = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(path); s.settimeout(0.3)
def drain(t):
    end = time.time() + t; out = b''
    while time.time() < end:
        try: out += s.recv(65536)
        except socket.timeout: pass
    return out
drain(0.5)
for l in lines:
    if l.startswith('SLEEP:'): time.sleep(float(l[6:])); continue
    s.sendall((l + '\r').encode()); sys.stdout.write(drain(settle).decode(errors='replace'))
s.close()
