#!/usr/bin/env python3
"""Writes the home-screen icons of the phone companion (mta/outbreak/ui/phone-icon-{180,192,512}.png): the Outbreak biohazard mark (three discs round a core, the same
glyph as the UI's `bio` icon) in amber on the UI's dark blue, drawn with 3x3 supersampling and written as plain PNG (zlib, no imaging library). Deterministic: re-running it
reproduces the files byte for byte.   python3 mta/tools/gen_phone_icons.py"""
import math, os, struct, zlib

BG, AMBER, DARK = (10, 14, 22), (246, 180, 79), (23, 30, 44)

def shape(x, y):
    """colour at unit coordinates (0..1): rounded dark plate, amber ring, bio glyph"""
    dx, dy = x - 0.5, y - 0.5
    r = math.hypot(dx, dy)
    c = BG
    if r < 0.46:
        c = DARK
    if 0.40 < r < 0.455:
        c = AMBER
    # glyph: core + three discs at 120 degrees (the UI icon: circles at (12,12.5) r1.8, (12,6.8) r2.8, (7,15.6) r2.8, (17,15.6) r2.8 on a 24 grid)
    def disc(cx, cy, rad): return math.hypot(x - cx, y - cy) < rad
    g = 24.0
    parts = [(12, 12.5, 1.8), (12, 6.8, 2.8), (7, 15.6, 2.8), (17, 15.6, 2.8)]
    s = 0.034  # 24 grid units -> unit square (times 1.12): the glyph spans about 0.42 of the icon
    for cx, cy, rad in parts:
        if disc(0.5 + (cx - 12) * s * 1.12, 0.5 + (cy - 12) * s * 1.12, rad * s * 1.12): c = AMBER
    # connecting arms as thin bars from the core to each disc
    for cx, cy, _ in parts[1:]:
        px, py = 0.5, 0.5 + 0.5 * s * 1.12
        qx, qy = 0.5 + (cx - 12) * s * 1.12, 0.5 + (cy - 12) * s * 1.12
        vx, vy = qx - px, qy - py
        t = max(0.0, min(1.0, ((x - px) * vx + (y - py) * vy) / (vx * vx + vy * vy)))
        if math.hypot(x - (px + t * vx), y - (py + t * vy)) < 0.012: c = AMBER
    return c

def png(size):
    ss = 3
    raw = bytearray()
    for j in range(size):
        raw.append(0)
        for i in range(size):
            acc = [0, 0, 0]
            for b in range(ss):
                for a in range(ss):
                    c = shape((i + (a + 0.5) / ss) / size, (j + (b + 0.5) / ss) / size)
                    acc[0] += c[0]; acc[1] += c[1]; acc[2] += c[2]
            raw += bytes(int(round(v / (ss * ss))) for v in acc)
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "outbreak", "ui")
for n in (180, 192, 512):
    with open(os.path.join(out, "phone-icon-%d.png" % n), "wb") as f:
        f.write(png(n))
    print("wrote phone-icon-%d.png" % n)
