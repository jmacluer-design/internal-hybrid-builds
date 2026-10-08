"""Extract a map's packed models and physics files (for the harness and the
skatecheck tool):  python extract_pak.py tl_skatepark.bsp pak"""
import io, os, struct, sys, zipfile
bsp, out = sys.argv[1], sys.argv[2]
with open(bsp, 'rb') as f:
    hdr = f.read(8 + 64 * 16)
    off, length, _, _ = struct.unpack('<iiii', hdr[8 + 40 * 16:8 + 41 * 16])  # lump 40: the pakfile
    f.seek(off)
    z = zipfile.ZipFile(io.BytesIO(f.read(length)))
n = 0
for name in z.namelist():
    if name.lower().endswith(('.mdl', '.phy')):
        path = os.path.join(out, name.lower())
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'wb') as g:
            g.write(z.read(name))
        n += 1
print(n, 'files extracted to', out)
