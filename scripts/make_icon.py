#!/usr/bin/env python3
"""Generates Lumora's 1024x1024 app icon with no dependencies (pure-Python PNG writer).
Design: deep teal-to-indigo background, a warm glowing sun disc resting on three
horizon 'slider' lines."""
import math, struct, sys, zlib

S = 1024
out = sys.argv[1] if len(sys.argv) > 1 else "icon-1024.png"

def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))

def clamp(x):
    return 0 if x < 0 else 255 if x > 255 else int(x)

top, bottom = (16, 46, 64), (24, 18, 52)
sun_in, sun_out = (255, 214, 120), (255, 120, 70)
cx, cy, R = 512, 470, 230
lines = [(700, 150, 874, (255, 255, 255)), (770, 220, 804, (120, 220, 230)), (840, 290, 734, (255, 170, 110))]

rows = []
for y in range(S):
    row = bytearray([0])
    for x in range(S):
        c = mix(top, bottom, y / S)
        d = math.hypot(x - cx, y - cy)
        # glow
        g = max(0.0, 1 - d / (R * 1.9)) ** 2 * 0.55
        c = mix(c, sun_out, g)
        if d < R and y < 640:
            t = min(1.0, d / R)
            c = mix(sun_in, sun_out, t ** 1.6)
        elif d < R + 2 and y < 640:
            c = mix(c, sun_out, 0.5)
        for (ly, x0, x1, col) in lines:
            if x0 <= x <= x1 and abs(y - ly) <= 14:
                edge = min(1.0, (14 - abs(y - ly)) / 2.0)
                c = mix(c, col, edge)
        row += bytes((clamp(c[0]), clamp(c[1]), clamp(c[2])))
    rows.append(bytes(row))

raw = b"".join(rows)
def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 2, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
open(out, "wb").write(png)
print("wrote", out)
