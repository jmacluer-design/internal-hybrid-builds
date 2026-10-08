"""The map's static props' physics shapes from Garry's Mod's own content.

extract_pak.py takes the .phy files packed into a map; most workshop maps use
stock HL2 / GMod models instead, whose .phy files live in the game's VPKs.
This writes them to the same kind of folder (models/....phy), for SK8_PAK:

    python extract_props.py <map.bsp> <garrysmod install dir> <out dir>
"""
import os
import struct
import sys


def static_prop_models(bsp):
    d = open(bsp, 'rb').read()
    off, length = struct.unpack_from('<ii', d, 8 + 35 * 16)
    n = struct.unpack_from('<i', d, off)[0]
    names = set()
    o = off + 4
    for _ in range(n):
        gid, flags, ver, goff, glen = struct.unpack_from('<4sHHii', d, o)
        o += 16
        if gid[::-1] == b'sprp' or gid == b'prps':
            k = struct.unpack_from('<i', d, goff)[0]
            for i in range(k):
                raw = d[goff + 4 + i * 128: goff + 4 + (i + 1) * 128]
                names.add(raw.split(b'\0', 1)[0].decode('latin1').lower().replace('\\', '/'))
    return names


def read_vpk(path, exts=('phy',)):
    """{lower path: (archive index, offset, length, preload bytes)} from a _dir.vpk"""
    f = open(path, 'rb')
    sig, ver, tree = struct.unpack('<III', f.read(12))
    if ver == 2:
        f.read(16)
    entries = {}

    def cstr():
        b = b''
        while True:
            c = f.read(1)
            if c in (b'\0', b''):
                return b.decode('latin1')
            b += c
    while True:
        ext = cstr()
        if not ext:
            break
        while True:
            folder = cstr()
            if not folder:
                break
            while True:
                name = cstr()
                if not name:
                    break
                crc, pre, arc, off, ln, term = struct.unpack('<IHHIIH', f.read(18))
                data = f.read(pre)
                if ext in exts:
                    full = ((folder + '/') if folder.strip() else '') + name + '.' + ext
                    entries[full.lower()] = (arc, off, ln, data, f.tell())
    header_end = 12 + (16 if ver == 2 else 0) + tree
    return entries, header_end


def main():
    bsp, gmod, out = sys.argv[1], sys.argv[2], sys.argv[3]
    want = {m[:-4] + '.phy' for m in static_prop_models(bsp) if m.endswith('.mdl')}
    vpks = [os.path.join(gmod, 'garrysmod', 'garrysmod_dir.vpk')]
    se = os.path.join(gmod, 'sourceengine')
    vpks += [os.path.join(se, f) for f in sorted(os.listdir(se)) if f.endswith('_dir.vpk')]
    found = 0
    for vpk in vpks:
        if not os.path.exists(vpk):
            continue
        entries, header_end = read_vpk(vpk)
        for p in list(want):
            e = entries.get(p)
            if not e:
                continue
            arc, off, ln, pre, _ = e
            if arc == 0x7fff:
                with open(vpk, 'rb') as f:
                    f.seek(header_end + off)
                    data = pre + f.read(ln)
            else:
                with open(vpk.replace('_dir.vpk', '_%03d.vpk' % arc), 'rb') as f:
                    f.seek(off)
                    data = pre + f.read(ln)
            dst = os.path.join(out, p)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            open(dst, 'wb').write(data)
            want.discard(p)
            found += 1
    print('%d prop shapes from the game, %d not found (models without physics, or from other content)' % (found, len(want)))


if __name__ == '__main__':
    main()
