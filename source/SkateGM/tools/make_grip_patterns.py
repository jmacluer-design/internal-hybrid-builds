"""Writes the grip tape patterns: white shapes on transparent, 64x64 and
seamlessly tileable, tinted per player in game (materials/skategm/grip/)."""
import math, os
import vtf

SIZE, SS = 64, 4
OUT = os.path.join(os.path.dirname(__file__), "..", "addon", "skategm", "materials", "skategm", "grip")


def star(x, y, cx, cy, r):
    dx, dy = x - cx, y - cy
    a = math.atan2(dy, dx) + math.pi / 2
    d = math.hypot(dx, dy)
    k = (a % (2 * math.pi / 5)) / (2 * math.pi / 5)
    edge = r * (0.5 + 0.5 * abs(2 * k - 1))
    return d <= edge


def wrap_near(x, y, cx, cy):
    return min(((x - cx + SIZE / 2) % SIZE) - SIZE / 2, key=abs), min(((y - cy + SIZE / 2) % SIZE) - SIZE / 2, key=abs)


def tdist(x, y, cx, cy):
    dx = (x - cx + SIZE / 2) % SIZE - SIZE / 2
    dy = (y - cy + SIZE / 2) % SIZE - SIZE / 2
    return math.hypot(dx, dy), dx, dy


def camo(x, y):
    v = 0
    for kx, ky, ph in ((1, 0, 0.3), (0, 1, 1.1), (1, 1, 2.0), (2, -1, 0.7), (1, 2, 2.6), (3, 1, 1.9), (-2, 3, 0.2)):
        v += math.sin(2 * math.pi * (kx * x + ky * y) / SIZE + ph) / (abs(kx) + abs(ky))
    return v > 0.35


PATTERNS = {
    "stripes": lambda x, y: (y // 8) % 2 == 0,
    "diagonal": lambda x, y: ((x + y) % 32) < 12,
    "checker": lambda x, y: ((x // 16) + (y // 16)) % 2 == 0,
    "dots": lambda x, y: min(tdist(x, y, 16, 16)[0], tdist(x, y, 48, 48)[0]) <= 8,
    "camo": camo,
    "zigzag": lambda x, y: ((y + abs((x % 32) - 16)) % 16) < 6,
    "grid": lambda x, y: (x % 16) < 2.5 or (y % 16) < 2.5,
    "stars": lambda x, y: any(star(16 + tdist(x, y, cx, cy)[1], 16 + tdist(x, y, cx, cy)[2], 16, 16, 11) for cx, cy in ((16, 16), (48, 48))),
}

os.makedirs(OUT, exist_ok=True)
for name, fn in PATTERNS.items():
    px = []
    for y in range(SIZE):
        for x in range(SIZE):
            hits = sum(1 for sy in range(SS) for sx in range(SS) if fn(x + (sx + 0.5) / SS, y + (sy + 0.5) / SS))
            px.append((255, 255, 255, int(255 * hits / (SS * SS) + 0.5)))
    vtf.write(os.path.join(OUT, name + ".vtf"), px, SIZE, clamp=False)
    with open(os.path.join(OUT, name + ".vmt"), "w", newline="\n") as f:
        f.write('"UnlitGeneric"\n{\n\t"$basetexture" "skategm/grip/%s"\n\t"$vertexcolor" 1\n\t"$vertexalpha" 1\n\t"$translucent" 1\n\t"$nocull" 1\n}\n' % name)
print("wrote", len(PATTERNS), "patterns to", OUT)
