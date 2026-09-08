#!/usr/bin/env python3
"""Generate a soft abstract wallpaper PNG (no external deps).
   gen-wallpaper.py <out.png>                       default mylinux colours
   gen-wallpaper.py <out.png> <colors.toml> [seed]  derive it from a theme palette (background + accents)"""
import math, struct, zlib, os, sys, random
W, H = 1600, 1000
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "shell", "assets", "wallpaper.png")
def hexrgb(h): h = h.strip().strip('"').lstrip('#'); return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))
def lerp(a, b, t): return a + (b - a) * t
def mix(c1, c2, t): return tuple(lerp(c1[k], c2[k], t) for k in range(3))
stops = [(0.00, (18, 38, 74)), (0.45, (52, 96, 150)), (0.75, (150, 110, 170)), (1.00, (232, 140, 160))]
blobs = [(0.78, 0.22, 0.42, 0.34, (255, 170, 120), 0.55), (0.18, 0.80, 0.40, 0.30, (90, 200, 230), 0.45),
         (0.55, 0.62, 0.30, 0.26, (250, 120, 180), 0.35), (0.90, 0.85, 0.26, 0.22, (255, 220, 150), 0.40),
         (0.30, 0.25, 0.28, 0.20, (70, 120, 220), 0.35)]
if len(sys.argv) > 2:
    pal = {}
    for line in open(sys.argv[2]):
        if "=" in line: k, v = line.split("=", 1); pal[k.strip()] = v.strip()
    bg = hexrgb(pal.get("background", "#1a1b26")); acc = hexrgb(pal.get("accent", pal.get("color4", "#7aa2f7")))
    light = sum(bg) / 3 > 128
    cols = [hexrgb(pal[k]) for k in ("color1", "color2", "color3", "color4", "color5", "color6") if k in pal] or [acc]
    # background field: dark themes drift from the bg towards a dimmed accent; light themes stay pale
    far = mix(bg, acc, 0.35 if not light else 0.18)
    stops = [(0.0, bg), (0.55, mix(bg, far, 0.6)), (1.0, far)]
    rnd = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 7)
    blobs = []
    for i, c in enumerate(cols[:5]):
        blobs.append((rnd.uniform(0.1, 0.9), rnd.uniform(0.1, 0.9), rnd.uniform(0.22, 0.42), rnd.uniform(0.18, 0.34),
                      mix(c, bg, 0.25 if not light else 0.55), rnd.uniform(0.28, 0.5)))
def base(t):
    for i in range(len(stops) - 1):
        t0, c0 = stops[i]; t1, c1 = stops[i + 1]
        if t <= t1:
            u = (t - t0) / (t1 - t0); u = u * u * (3 - 2 * u)
            return tuple(lerp(c0[k], c1[k], u) for k in range(3))
    return stops[-1][1]
rows = []
for y in range(H):
    row = bytearray([0]); fy = y / H
    for x in range(W):
        fx = x / W
        r, g, b = base(fx * 0.55 + fy * 0.45)
        for (cx, cy, rx, ry, col, s) in blobs:
            dx = (fx - cx) / rx; dy = (fy - cy) / ry; d = dx * dx + dy * dy
            if d < 1.0:
                a = s * (1 - d) ** 2
                r = lerp(r, col[0], a); g = lerp(g, col[1], a); b = lerp(b, col[2], a)
        v = 1 - 0.18 * ((fx - 0.5) ** 2 + (fy - 0.5) ** 2) * 2
        row += bytes((int(min(255, r * v)), int(min(255, g * v)), int(min(255, b * v))))
    rows.append(bytes(row))
raw = b"".join(rows)
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
open(out, "wb").write(png); print(out, len(png) // 1024, "KB")
