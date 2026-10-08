"""compare.py a.txt b.txt [c.txt ...]: totals per results file, and the spots whose outcome differs."""
import re, sys
def load(p):
    d = {}
    for l in open(p):
        m = re.match(r'run (\d+): (\w+) \(([^)]*)\)', l)
        if m: d[int(m.group(1))] = (m.group(2), m.group(3))
    return d
files = sys.argv[1:]
runs = [load(f) for f in files]
short = {'real obstacle ahead': 'R', 'UNEXPLAINED': 'U', 'lip ahead': 'L', 'drop-off ahead': 'R', 'after a landing': 'A', '-': '', 'not riding after settling': '', 'moved away while settling': ''}
for f, d in zip(files, runs):
    c = {}
    for res, why in d.values():
        c[res] = c.get(res, 0) + 1
        if res not in ('clean', 'badspot'): c[short.get(why, why)] = c.get(short.get(why, why), 0) + 1
    print(f"{f:40s} n {len(d):3d}  clean {c.get('clean',0):3d}  bail {c.get('bail',0):2d}  runout {c.get('runout',0):2d}  drop {c.get('drop',0):3d}  badspot {c.get('badspot',0):2d}  fell {c.get('fellthrough',0):2d} | real {c.get('R',0):3d} lip {c.get('L',0):2d} landing {c.get('A',0):2d} unexplained {c.get('U',0):2d}")
common = sorted(set.intersection(*[set(d) for d in runs]))
diff = [r for r in common if len({d[r][0] for d in runs}) > 1]
print(f"spots in all files: {len(common)}; outcome differs at {len(diff)}:")
for r in diff:
    print(f"  {r:4d} " + "  ".join(f"{d[r][0]}{short.get(d[r][1], d[r][1])}" for d in runs))
