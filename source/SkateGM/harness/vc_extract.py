"""gm_infmap_vicecity's ground for the harness, built as the map builds it.

Each chunk collider (vicecity_collider) takes the first mesh of
models/vicecitychunkscol/<x>_<y>_0_col[_NNN].mdl, turns it -90 degrees, scales
it by 39.3701 (metres to inches); the map's .obj collision (InfMap.parse_obj,
loadobject.lua) is translated by (0, 0, -300), turned 180 degrees and scaled
the same. Both come out here as absolute triangles, one Lua file per chunk
(chunk size 5000, so chunks are 10000 wide):

    python vc_extract.py <extracted gma dir> <out dir>
"""
import os
import re
import struct
import sys
from collections import defaultdict

K = 39.3701
CHUNK_W = 10000


def vvd_vertices(path):
    d = open(path, 'rb').read()
    num_lods = struct.unpack_from('<i', d, 12)[0]
    lod_verts = struct.unpack_from('<8i', d, 16)
    num_fix, fix_off, vert_off, _ = struct.unpack_from('<4i', d, 48)

    def vert(i):
        o = vert_off + i * 48 + 16
        return struct.unpack_from('<3f', d, o)
    if num_fix == 0:
        return [vert(i) for i in range(lod_verts[0])]
    out = []
    for f in range(num_fix):
        lod, src, n = struct.unpack_from('<3i', d, fix_off + f * 12)
        if lod >= 0:
            out.extend(vert(src + k) for k in range(n))
    return out


def vtx_first_mesh(path, nverts):
    """Triangle indices (into the model's vertices) of LOD 0's first mesh."""
    d = open(path, 'rb').read()
    num_bodyparts, bodypart_off = struct.unpack_from('<2i', d, 28)
    for sg_size in (25, 33):
        try:
            bp = bodypart_off
            num_models, model_off = struct.unpack_from('<2i', d, bp)
            mdl = bp + model_off
            num_lods, lod_off = struct.unpack_from('<2i', d, mdl)
            lod = mdl + lod_off
            num_meshes, mesh_off = struct.unpack_from('<2i', d, lod)
            mesh = lod + mesh_off
            num_sg, sg_off = struct.unpack_from('<2i', d, mesh)
            tris = []
            for g in range(num_sg):
                sg = mesh + sg_off + g * sg_size
                nv, voff, ni, ioff, ns, soff = struct.unpack_from('<6i', d, sg)
                verts = [struct.unpack_from('<H', d, sg + voff + k * 9 + 4)[0] for k in range(nv)]
                idx = struct.unpack_from('<%dH' % ni, d, sg + ioff)
                for k in range(0, ni - 2, 3):
                    a, b, c = verts[idx[k]], verts[idx[k + 1]], verts[idx[k + 2]]
                    if max(a, b, c) >= nverts:
                        raise ValueError('index out of range')
                    tris.append((a, b, c))
            return tris
        except (ValueError, IndexError, struct.error):
            continue
    raise ValueError('could not read ' + path)


def chunk_of(v):
    return tuple(int((c + CHUNK_W / 2) // CHUNK_W) for c in v[:2])


def obj_triangles(path):
    verts, tris = [], []
    for line in open(path, encoding='latin1'):
        if line.startswith('v '):
            x, y, z = map(float, line.split()[1:4])
            x, y, z = x * K, y * K, z * K
            verts.append((-x, -y, z - 300))
        elif line.startswith('f '):
            ids = [int(p.split('/')[0]) for p in line.split()[1:]]
            ids = [i - 1 if i > 0 else len(verts) + i for i in ids]
            for k in range(1, len(ids) - 1):
                a, b, c = verts[ids[0]], verts[ids[k]], verts[ids[k + 1]]
                ux, uy, uz = b[0] - a[0], b[1] - a[1], b[2] - a[2]
                vx, vy, vz = c[0] - a[0], c[1] - a[1], c[2] - a[2]
                cx, cy, cz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
                if cx * cx + cy * cy + cz * cz < 100000:
                    continue
                tris.append((a, b, c))
    return tris


def main():
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    chunks = defaultdict(list)
    mdir = os.path.join(src, 'models', 'vicecitychunkscol')
    bad = 0
    for name in sorted(os.listdir(mdir)):
        m = re.match(r'^(-?\d+)_(-?\d+)_0_col(_\d{3})?\.mdl$', name)
        if not m:
            continue
        base = os.path.join(mdir, name[:-4])
        try:
            v = vvd_vertices(base + '.vvd')
            t = vtx_first_mesh(base + '.dx90.vtx', len(v))
        except Exception as e:
            bad += 1
            print('skipped', name, e)
            continue
        key = (int(m.group(1)), int(m.group(2)))
        for a, b, c in t:
            tri = []
            for i in (a, b, c):
                x, y, z = v[i]
                tri.append((y * K, -x * K, z * K))
            chunks[key].extend(tri)
    obj_dir = os.path.join(src, 'maps')
    nobj = 0
    for name in os.listdir(obj_dir):
        if '.obj' in name and not name.endswith('.mtl.ain'):
            for tri in obj_triangles(os.path.join(obj_dir, name)):
                cx = sum(p[0] for p in tri) / 3
                cy = sum(p[1] for p in tri) / 3
                chunks[chunk_of((cx, cy))].extend(tri)
                nobj += 1
    total = 0
    for (x, y), pts in chunks.items():
        total += len(pts) // 3
        with open(os.path.join(out, '%d_%d.lua' % (x, y)), 'w') as f:
            f.write('return {')
            f.write(','.join('%.2f,%.2f,%.2f' % p for p in pts))
            f.write('}\n')
    print('%d chunks, %d triangles (%d from the .obj), %d models skipped' % (len(chunks), total, nobj, bad))


if __name__ == '__main__':
    main()
