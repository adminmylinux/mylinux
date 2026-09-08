#!/usr/bin/env python3
"""Render the myLinux app icon (512x512 PNG, no deps): rounded gradient square + window glyph."""
import struct, zlib, sys, math
out = sys.argv[1]; N = 512
def lerp(a, b, t): return a + (b - a) * t
def inside_rrect(x, y, x0, y0, x1, y1, r):
    cx = min(max(x, x0 + r), x1 - r); cy = min(max(y, y0 + r), y1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r
rows = []
for y in range(N):
    row = bytearray([0])
    for x in range(N):
        t = (x + y) / (2 * N)
        r, g, b = lerp(28, 220, t), lerp(58, 120, t), lerp(110, 160, t)   # blue -> pink
        a = 255 if inside_rrect(x, y, 26, 26, N - 26, N - 26, 110) else 0
        # window glyph: white card with title bar and three dots
        if inside_rrect(x, y, 116, 150, N - 116, N - 130, 26):
            r, g, b = 246, 246, 248
            if y < 200: r, g, b = 226, 226, 232
            for i, col in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
                if (x - (148 + i * 30)) ** 2 + (y - 175) ** 2 <= 100: r, g, b = col
        row += bytes((int(r), int(g), int(b), a))
    rows.append(bytes(row))
raw = b"".join(rows)
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", N, N, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
open(out, "wb").write(png); print(out)
