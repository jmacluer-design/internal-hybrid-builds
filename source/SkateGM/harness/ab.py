"""ab.py: a paired A/B comparison with the real engine, in one command.

    python ab.py --map pf --name hidden --b SK8_ON=hiddenoutline
    python ab.py --map tl --features 1 --name rails --a SK8_OFF_ADD=rampsides
    python ab.py --map gms --near "150 -780 300" --name wall --b SK8_ON=hiddenoutline
    python ab.py --map pf --name release --dll-a old.dll --dll-b new.dll

Runs config A and config B (each a list of ENV=value) --runs times each, all at
once at idle priority (the PC stays usable), with the same DLL and the map's
saved spots, then prints compare.py's table: A runs first, then B. Results go
to results/<map dir>/ab_<name>_<a|b>_<n>.txt. --near "x y r" rides only the
spots within r of x, y (the harness's SK8_NEAR), numbered as in full runs.
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def local_env():
    """KEY=VALUE lines from harness/local.env (git-ignored), under the environment"""
    path = os.path.join(HERE, 'local.env')
    if os.path.exists(path):
        for line in open(path, encoding='utf-8'):
            k, sep, v = line.strip().partition('=')
            if sep and not k.startswith('#'):
                os.environ.setdefault(k.strip(), v.strip())


local_env()
MAPS = os.environ.get('SK8_MAPS', os.path.join(HERE, '..', '..', 'maps'))
DATA = os.environ.get('SK8_DATA', os.path.join(os.environ.get('LOCALAPPDATA', '.'), 'SkateGM', 'data', 'assets'))

# map: (bsp, pak dir, spots dir, centre)
PRESETS = {
    'tl': (os.path.join(MAPS, 'maps', 'tl_skatepark.bsp'), 'pak', 'results', '-2600 -700 420'),
    'pf': (os.path.join(MAPS, 'pf', 'maps', 'pf_skatepark.bsp'), 'pak_pf', 'results/pf', '-3072 2048 -150'),
    'indoor': (os.path.join(MAPS, 'indoor', 'maps', 'gm_indoor_skatepark.bsp'), 'pak_indoor', 'results/indoor', '86 678 -215'),
    'gms': (os.path.join(MAPS, 'gms', 'maps', 'gm_skatepark.bsp'), 'pak_gms', 'results/gms', '-224 -252 65'),
    'slopes': (os.path.join(MAPS, 'slopes', 'maps', 'gm_slopes.bsp'), 'pak_ramp', 'results/slopes', '-11008 10432 4352'),
    'fork': (os.path.join(MAPS, 'fork', 'maps', 'gm_fork.bsp'), 'pak_fork', 'results/fork/a', '11264 -2048 -7686'),
    'wh': (os.path.join(HERE, '..', 'addon', 'skategm', 'maps', 'sgm_warehouse.bsp'), 'pak_wh', 'results/wh', '0 0 8'),
}

IDLE = 0x00000040  # IDLE_PRIORITY_CLASS (Windows)


def env_list(items):
    out = {}
    for it in items or []:
        k, _, v = it.partition('=')
        out[k] = v
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--map', required=True, choices=sorted(PRESETS))
    ap.add_argument('--name', required=True)
    ap.add_argument('--a', nargs='*', default=[], help='config A: ENV=value ...')
    ap.add_argument('--b', nargs='*', default=[], help='config B: ENV=value ...')
    ap.add_argument('--runs', type=int, default=2)
    ap.add_argument('--rides', type=int, default=120)
    ap.add_argument('--features', default=None, help='SK8_FEATURES (1, ledges, ledgesdown)')
    ap.add_argument('--near', default=None, help='"x y r": only spots within r of x, y')
    ap.add_argument('--style', default='classic')
    ap.add_argument('--dll', default=os.path.join(HERE, '..', 'gm_skategm', 'prebuilt', 'gmcl_skategm_win64.dll'))
    ap.add_argument('--dll-a', default=None, help='a different DLL for config A (comparing builds)')
    ap.add_argument('--dll-b', default=None, help='a different DLL for config B')
    args = ap.parse_args()

    bsp, pak, spots_dir, centre = PRESETS[args.map]
    out_dir = os.path.join(HERE, spots_dir)
    common = {'SK8_DATA': DATA, 'SK8_MAP': os.path.abspath(bsp),
              'SK8_PAK': pak, 'SK8_SPOTS_DIR': spots_dir}
    if args.features:
        common['SK8_FEATURES'] = args.features
    if args.near:
        common['SK8_NEAR'] = args.near
    luajit = os.path.join(HERE, 'win', 'luajit.exe')
    procs, outs = [], {'a': [], 'b': []}
    dlls = {'a': args.dll_a or args.dll, 'b': args.dll_b or args.dll}
    for side, extra in (('a', env_list(args.a)), ('b', env_list(args.b))):
        extra = dict(extra, SK8_DLL=os.path.abspath(dlls[side]))
        for n in range(1, args.runs + 1):
            out = os.path.join(out_dir, 'ab_%s_%s_%d.txt' % (args.name, side, n))
            if os.path.exists(out):
                os.remove(out)
            outs[side].append(out)
            env = dict(os.environ, **common, **extra)
            cmd = [luajit, 'harness.lua', args.style, str(args.rides), '11'] + centre.split() + [out]
            flags = IDLE if sys.platform == 'win32' else 0
            procs.append(subprocess.Popen(cmd, cwd=HERE, env=env, stdout=subprocess.DEVNULL,
                                          stderr=subprocess.DEVNULL, creationflags=flags))
    for p in procs:
        p.wait()
    subprocess.run([sys.executable, os.path.join(HERE, 'compare.py')] + outs['a'] + outs['b'], cwd=HERE)


if __name__ == '__main__':
    main()
