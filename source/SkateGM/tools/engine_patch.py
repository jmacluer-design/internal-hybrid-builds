"""Write engine/CHANGES.patch: every change in engine/ against the upstream commit.

    python tools/engine_patch.py <clone of 2010-rust-rewrite-mashup>

The clone only needs the upstream commit; its working tree isn't used.
"""
import os
import shutil
import subprocess
import sys
import tempfile

UPSTREAM = '65d9e117bdec651146e4fe26a903893b4b86e486'
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OURS_ONLY = {'README.md', 'LICENSE', 'NOTICE-mashup', 'CHANGES.patch'}


def git(*args, cwd=ROOT, **kw):
    return subprocess.run(['git', *args], cwd=cwd, check=True, capture_output=True, **kw).stdout


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    clone = sys.argv[1]
    tmp = tempfile.mkdtemp()
    try:
        a, b = os.path.join(tmp, 'a'), os.path.join(tmp, 'b')
        os.makedirs(a)
        tar = git('archive', UPSTREAM, 'skate/Cargo.toml', 'skate/crates', cwd=clone)
        subprocess.run(['tar', '-x', '-C', a, '--strip-components=1'], input=tar, check=True)
        for path in git('ls-files', 'engine').decode().splitlines():
            rel = path[len('engine/'):]
            if rel in OURS_ONLY:
                continue
            dst = os.path.join(b, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(os.path.join(ROOT, path), dst)
        diff = subprocess.run(['git', 'diff', '--no-index', '--no-color', '--src-prefix=', '--dst-prefix=', 'a', 'b'],
                              cwd=tmp, capture_output=True).stdout
        out = os.path.join(ROOT, 'engine', 'CHANGES.patch')
        with open(out, 'wb') as f:
            f.write(diff.replace(b'\r\n', b'\n'))
        print('%s: %d lines' % (out, diff.count(b'\n')))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    main()
