"""Builds sgm_warehouse: an empty warehouse to build parks in (the park
editor's parts), like Skate 3's. Writes maps/src/sgm_warehouse.vmf and
compiles it with Garry's Mod's own vbsp / vvis / vrad into
addon/skategm/maps/sgm_warehouse.bsp. Stock HL2 textures only.

    python tools/make_warehouse.py [--gmod DIR] [--fast]
"""
import argparse
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NAME = 'sgm_warehouse'

HALF_X, HALF_Y = 3072, 2048
HEIGHT = 640
WALL = 32
ROOF = 32
SKYLIGHT_W = 192
SKYLIGHTS_X = (-2048, -1024, 0, 1024, 2048)
SKYLIGHT_HALF_Y = 1536
SHAFT = 64
SUN, AMBIENT, LAMP = 110, 35, 110
BLOOM = 0.2

FLOOR = 'concrete/concretefloor002a'
WALLS = 'metal/metalwall001a'
SKIRT = 'concrete/concretewall001a'
SKIRT_H = 96
ROOF_TEX = 'metal/metalroof005a'
NODRAW = 'tools/toolsnodraw'
SKY = 'tools/toolsskybox'


class Vmf:
    def __init__(self):
        self.next = 1
        self.solids = []
        self.entities = []

    def id(self):
        self.next += 1
        return self.next

    def box(self, x1, y1, z1, x2, y2, z2, tex, scale=32, inner=None):
        """an axis-aligned brush; tex is one texture or {side: texture}
        (sides top, bottom, -x, +x, +y, -y)"""
        planes = {
            'top': ((x1, y2, z2), (x2, y2, z2), (x2, y1, z2)),
            'bottom': ((x1, y1, z1), (x2, y1, z1), (x2, y2, z1)),
            '-x': ((x1, y2, z2), (x1, y1, z2), (x1, y1, z1)),
            '+x': ((x2, y2, z1), (x2, y1, z1), (x2, y1, z2)),
            '+y': ((x2, y2, z2), (x1, y2, z2), (x1, y2, z1)),
            '-y': ((x2, y1, z1), (x1, y1, z1), (x1, y1, z2)),
        }
        axes = {
            'top': ('[1 0 0 0] 0.25', '[0 -1 0 0] 0.25'),
            'bottom': ('[1 0 0 0] 0.25', '[0 -1 0 0] 0.25'),
            '-x': ('[0 1 0 0] 0.25', '[0 0 -1 0] 0.25'),
            '+x': ('[0 1 0 0] 0.25', '[0 0 -1 0] 0.25'),
            '+y': ('[1 0 0 0] 0.25', '[0 0 -1 0] 0.25'),
            '-y': ('[1 0 0 0] 0.25', '[0 0 -1 0] 0.25'),
        }
        sides = []
        for side, pts in planes.items():
            t = tex.get(side, NODRAW) if isinstance(tex, dict) else tex
            plane = ' '.join('(%g %g %g)' % p for p in pts)
            u, v = axes[side]
            sides.append(
                '\tside\n\t{\n\t\t"id" "%d"\n\t\t"plane" "%s"\n\t\t"material" "%s"\n'
                '\t\t"uaxis" "%s"\n\t\t"vaxis" "%s"\n\t\t"rotation" "0"\n'
                '\t\t"lightmapscale" "%d"\n\t\t"smoothing_groups" "0"\n\t}\n'
                % (self.id(), plane, t.upper(), u, v, scale))
        self.solids.append('solid\n{\n\t"id" "%d"\n%s}\n' % (self.id(), ''.join(sides)))

    def entity(self, cls, connections=(), **kv):
        body = ''.join('\t"%s" "%s"\n' % (k, v) for k, v in kv.items())
        if connections:
            body += '\tconnections\n\t{\n' + ''.join('\t\t"%s" "%s"\n' % c for c in connections) + '\t}\n'
        self.entities.append('entity\n{\n\t"id" "%d"\n\t"classname" "%s"\n%s}\n' % (self.id(), cls, body))

    def text(self):
        world = ('world\n{\n\t"id" "1"\n\t"mapversion" "1"\n\t"classname" "worldspawn"\n'
                 '\t"skyname" "sky_day01_01"\n\t"maxpropscreenwidth" "-1"\n'
                 '\t"detailvbsp" "detail.vbsp"\n\t"detailmaterial" "detail/detailsprites"\n')
        return ('versioninfo\n{\n\t"editorversion" "400"\n\t"mapversion" "1"\n\t"formatversion" "100"\n'
                '\t"prefab" "0"\n}\n' + world + ''.join(self.solids) + '}\n' + ''.join(self.entities))


def build():
    m = Vmf()
    x1, x2, y1, y2 = -HALF_X, HALF_X, -HALF_Y, HALF_Y
    # the floor: one brush, so the skater rolls on one flat face
    m.box(x1, y1, -WALL, x2, y2, 0, {'top': FLOOR})
    # walls: a concrete skirt at the bottom, metal above, nodraw outside
    for (a, b, c, d, face) in (
        (x1 - WALL, y1 - WALL, x1, y2 + WALL, '+x'),
        (x2, y1 - WALL, x2 + WALL, y2 + WALL, '-x'),
        (x1, y1 - WALL, x2, y1, '+y'),
        (x1, y2, x2, y2 + WALL, '-y'),
    ):
        m.box(a, b, -WALL, c, d, SKIRT_H, {face: SKIRT}, scale=16)
        m.box(a, b, SKIRT_H, c, d, HEIGHT, {face: WALLS})
    # the roof, with skylight slots (shafts capped with sky) across it
    edges = [x1]
    for sx in SKYLIGHTS_X:
        edges += [sx - SKYLIGHT_W // 2, sx + SKYLIGHT_W // 2]
    edges.append(x2)
    for a, b in zip(edges[0::2], edges[1::2]):
        m.box(a, y1, HEIGHT, b, y2, HEIGHT + ROOF, {'bottom': ROOF_TEX})
    for sx in SKYLIGHTS_X:
        a, b = sx - SKYLIGHT_W // 2, sx + SKYLIGHT_W // 2
        m.box(a, y1, HEIGHT, b, -SKYLIGHT_HALF_Y, HEIGHT + ROOF, {'bottom': ROOF_TEX})
        m.box(a, SKYLIGHT_HALF_Y, HEIGHT, b, y2, HEIGHT + ROOF, {'bottom': ROOF_TEX})
        top = HEIGHT + ROOF + SHAFT
        m.box(a - WALL, -SKYLIGHT_HALF_Y - WALL, HEIGHT + ROOF, a, SKYLIGHT_HALF_Y + WALL, top, {'+x': ROOF_TEX})
        m.box(b, -SKYLIGHT_HALF_Y - WALL, HEIGHT + ROOF, b + WALL, SKYLIGHT_HALF_Y + WALL, top, {'-x': ROOF_TEX})
        m.box(a, -SKYLIGHT_HALF_Y - WALL, HEIGHT + ROOF, b, -SKYLIGHT_HALF_Y, top, {'+y': ROOF_TEX})
        m.box(a, SKYLIGHT_HALF_Y, HEIGHT + ROOF, b, SKYLIGHT_HALF_Y + WALL, top, {'-y': ROOF_TEX})
        m.box(a - WALL, -SKYLIGHT_HALF_Y - WALL, top, b + WALL, SKYLIGHT_HALF_Y + WALL, top + WALL, SKY)
        # the skylights between roof and sky stay open (the shaft's inside)
    # light: daylight through the skylights, and lamps under the roof
    m.entity('light_environment', origin='0 0 %d' % (HEIGHT - 64), angles='0 30 0', pitch='-70',
             _light='255 245 230 %d' % SUN, _ambient='170 180 200 %d' % AMBIENT, _lightHDR='-1 -1 -1 1',
             _ambientHDR='-1 -1 -1 1', _lightscaleHDR='1', _AmbientScaleHDR='1', SunSpreadAngle='5')
    for lx in range(x1 + 512, x2, 1024):
        for ly in range(y1 + 512, y2, 1024):
            m.entity('light', origin='%d %d %d' % (lx, ly, HEIGHT - 48),
                     _light='255 240 215 %d' % LAMP, _lightHDR='-1 -1 -1 1', _lightscaleHDR='1',
                     _quadratic_attn='1', _fifty_percent_distance='640', _zero_percent_distance='1600')
    # softer HDR: little bloom, and the eye adapting only a little (the
    # skylights and lamps blew out the room)
    m.entity('env_tonemap_controller', targetname='tonemap', origin='0 0 64')
    m.entity('logic_auto', origin='0 0 80', spawnflags='1', connections=[
        ('OnMapSpawn', 'tonemap,SetBloomScale,%g,0,-1' % BLOOM),
        ('OnMapSpawn', 'tonemap,SetAutoExposureMin,0.7,0,-1'),
        ('OnMapSpawn', 'tonemap,SetAutoExposureMax,1.1,0,-1'),
    ])
    for lx in (-1536, 1536):
        m.entity('env_cubemap', origin='%d 0 128' % lx, cubemapsize='0')
    for i, (px, py, yaw) in enumerate(((0, -128, 90), (128, 0, 180), (0, 128, 270), (-128, 0, 0),
                                        (256, -256, 135), (-256, 256, 315), (256, 256, 225), (-256, -256, 45))):
        m.entity('info_player_start', origin='%d %d 8' % (px, py), angles='0 %d 0' % yaw)
    return m.text()


def thumbnail(path):
    """the map list's picture: the warehouse from above, light under the skylights"""
    try:
        from PIL import Image, ImageDraw, ImageFilter
    except ImportError:
        print('no Pillow: thumbnail left out')
        return
    size = 128
    img = Image.new('RGB', (size, size), (38, 40, 44))
    d = ImageDraw.Draw(img)
    sx, sy = (size - 16) / (2 * HALF_X), (size - 16) / (2 * HALF_X)
    cx, cy = size / 2, size / 2
    x1, y1 = cx - HALF_X * sx, cy - HALF_Y * sy
    x2, y2 = cx + HALF_X * sx, cy + HALF_Y * sy
    d.rectangle((x1 - 3, y1 - 3, x2 + 3, y2 + 3), fill=(92, 98, 106))
    d.rectangle((x1, y1, x2, y2), fill=(128, 128, 124))
    light = Image.new('L', (size, size), 0)
    ld = ImageDraw.Draw(light)
    for k in SKYLIGHTS_X:
        a, b = cx + (k - SKYLIGHT_W) * sx, cx + (k + SKYLIGHT_W) * sx
        ld.rectangle((a, cy - SKYLIGHT_HALF_Y * sy, b, cy + SKYLIGHT_HALF_Y * sy), fill=150)
    light = light.filter(ImageFilter.GaussianBlur(4))
    img.paste(Image.new('RGB', (size, size), (236, 232, 220)), (0, 0), light)
    for k in SKYLIGHTS_X:
        a, b = cx + (k - SKYLIGHT_W / 2) * sx, cx + (k + SKYLIGHT_W / 2) * sx
        d.rectangle((a, cy - SKYLIGHT_HALF_Y * sy, b, cy + SKYLIGHT_HALF_Y * sy), outline=(250, 248, 240))
    d.rectangle((x1, y1, x2, y2), outline=(70, 74, 80))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print('thumbnail', path)


def default_gmod():
    sys.path.insert(0, os.path.join(ROOT, 'installer'))
    from setup_skategm import find_gmod
    d = find_gmod()
    return str(d) if d and os.path.exists(os.path.join(d, 'bin', 'vbsp.exe')) else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--gmod', default=default_gmod())
    ap.add_argument('--fast', action='store_true', help='quick lighting (for testing)')
    a = ap.parse_args()
    src = os.path.join(ROOT, 'maps', 'src')
    os.makedirs(src, exist_ok=True)
    vmf = os.path.join(src, NAME + '.vmf')
    with open(vmf, 'w', newline='\n') as f:
        f.write(build())
    print('wrote', vmf)
    if not a.gmod:
        sys.exit('no Garry\'s Mod with bin/vbsp.exe found: pass --gmod')
    binv = os.path.join(a.gmod, 'bin')
    game = os.path.join(a.gmod, 'garrysmod')
    base = os.path.join(src, NAME)
    steps = [['vbsp.exe', '-game', game, base],
             ['vvis.exe'] + (['-fast'] if a.fast else []) + ['-game', game, base],
             ['vrad.exe'] + (['-fast'] if a.fast else ['-final']) + ['-both', '-game', game, base]]
    for s in steps:
        print('>', ' '.join(s))
        r = subprocess.run([os.path.join(binv, s[0])] + s[1:], cwd=binv, capture_output=True, text=True)
        log = r.stdout + r.stderr
        if r.returncode != 0 or '**** leaked ****' in log:
            print(log[-3000:])
            sys.exit('%s failed' % s[0])
    out = os.path.join(ROOT, 'addon', 'skategm', 'maps')
    thumbnail(os.path.join(out, 'thumb', NAME + '.png'))
    os.makedirs(out, exist_ok=True)
    shutil.copy(base + '.bsp', os.path.join(out, NAME + '.bsp'))
    print('built', os.path.join(out, NAME + '.bsp'), os.path.getsize(base + '.bsp') // 1024, 'KB')


if __name__ == '__main__':
    main()
