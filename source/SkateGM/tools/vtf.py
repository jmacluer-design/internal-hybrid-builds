"""Uncompressed VTF 7.2 (BGRA8888, full mip chain) writer for the add-on's
generated textures."""
import struct


def _half(px, size):
    out, n = [], size // 2
    for y in range(n):
        for x in range(n):
            q = [px[(2 * y + dy) * size + 2 * x + dx] for dy in (0, 1) for dx in (0, 1)]
            out.append(tuple(sum(p[i] for p in q) // 4 for i in range(4)))
    return out, n


def write(path, px, size, clamp=True):
    """px: size*size (r, g, b, a) tuples, row by row."""
    levels = [(px, size)]
    while levels[-1][1] > 1:
        levels.append(_half(*levels[-1]))
    flags = 0x2000 | (0x0004 | 0x0008 if clamp else 0)
    h = b"VTF\0" + struct.pack("<II", 7, 2) + struct.pack("<I", 80) + struct.pack("<HH", size, size) + struct.pack("<I", flags)
    h += struct.pack("<HH", 1, 0) + b"\0" * 4 + struct.pack("<fff", 1, 1, 1) + b"\0" * 4 + struct.pack("<f", 1.0)
    h += struct.pack("<I", 12) + struct.pack("<B", len(levels)) + struct.pack("<I", 0xFFFFFFFF) + struct.pack("<BB", 0, 0) + struct.pack("<H", 1)
    h = h.ljust(80, b"\0")
    data = b"".join(struct.pack("<BBBB", b, g, r, a) for lv, _ in reversed(levels) for r, g, b, a in lv)
    with open(path, "wb") as f:
        f.write(h + data)
