import os
import struct
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "exporter"))
import xiso

S = xiso.SECTOR


def check(label, ok):
    print("%-74s %s" % (label, "OK" if ok else "<-- WRONG"))


def entry(right, sector, size, attrs, name):
    raw = struct.pack("<HHIIBB", 0, right, sector, size, attrs, len(name)) + name.encode()
    return raw + b"\xff" * (-len(raw) % 4)


def table(*items):
    out = b""
    for i, (sector, size, attrs, name) in enumerate(items):
        first = entry(0, sector, size, attrs, name)
        right = (len(out) + len(first)) // 4 if i < len(items) - 1 else 0
        out += entry(right, sector, size, attrs, name)
    return out


def image(path, base):
    xex = b"XEX2" + b"x" * 5000
    big = bytes(range(256)) * 40
    anim = b"anim-file"
    anim_dir = table((70, len(anim), 0, "male.abin"))
    big_dir = table((64, len(big), 0, "db.big"))
    data_dir = table((52, len(big_dir), 0x10, "big"), (53, len(anim_dir), 0x10, "anim"))
    root = table((60, len(xex), 0, "default.xex"), (51, len(data_dir), 0x10, "data"))
    with open(path, "wb") as f:
        def at(sector, blob):
            f.seek(base + sector * S)
            f.write(blob)
        at(32, xiso.MAGIC + struct.pack("<II", 50, len(root)))
        at(50, root)
        at(51, data_dir)
        at(52, big_dir)
        at(53, anim_dir)
        at(60, xex)
        at(64, big)
        at(70, anim)
    return xex, big, anim


for label, base in (("a rebuilt image (partition at 0)", 0), ("a full XGD2 disc dump", 0xFD90000)):
    with tempfile.TemporaryDirectory() as tmp:
        iso = os.path.join(tmp, "game.iso")
        xex, big, anim = image(iso, base)
        with xiso.Xiso(iso) as disc:
            listed = dict(disc.walk())
        check(label + ": every file listed with its size", listed == {"default.xex": len(xex), "data/big/db.big": len(big), "data/anim/male.abin": len(anim)})
        out = os.path.join(tmp, "out")
        got = xiso.extract_files(iso, ["DEFAULT.XEX", "data/anim", "data/big/db.big"], out)
        read = lambda p: open(os.path.join(out, *p.split("/")), "rb").read()
        check("... files and whole folders copied out byte for byte (any case)", sorted(got) == ["data/anim/male.abin", "data/big/db.big", "default.xex"]
              and read("default.xex") == xex and read("data/big/db.big") == big and read("data/anim/male.abin") == anim)
        try:
            xiso.extract_files(iso, ["data/big/missing.big"], out)
            missing = False
        except xiso.XisoError:
            missing = True
        check("... a file that isn't on the disc is an error", missing)

with tempfile.TemporaryDirectory() as tmp:
    junk = os.path.join(tmp, "notadisc.iso")
    open(junk, "wb").write(b"\0" * 200000)
    try:
        xiso.Xiso(junk)
        refused = False
    except xiso.XisoError:
        refused = True
    check("something that isn't an Xbox disc image is refused", refused)
