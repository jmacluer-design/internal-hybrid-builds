"""Converts the Skate 3 data the gm_skategm module reads, from the player's own
Xbox 360 disc image (.iso) or extracted default.xex: animation banks, state graphs, input and physics
settings, and the skater model the board and rig are taken from.

Runs the converters of SK8-ENGINE/skate-3-rust-engine (copied into ./tools,
commit cb79689). Nothing is downloaded and nothing from the game is bundled.
Adapted from 2010 Rust Rewrite Mashup's skate/converter/iw4l_skate_convert.py.

    python convert.py --xex <default.xex or the game's .iso> --out <folder>

Writes <folder>/assets on success; progress lines go to stdout.
"""
from pathlib import Path
import argparse, runpy, shutil, sys, tempfile, traceback

ROOT = Path(getattr(sys, '_MEIPASS', Path(__file__).resolve().parent))
sys.path.insert(0, str(ROOT))

REQUIRED = [
    'data/big/miscload.big',
    'data/big/miscboot.big',
    'data/big/db.big',
    'data/content/createacharacter.big',
]


def run_task(script, args):
    # The converters start their own helper scripts through `--task`.
    script = Path(script)
    if not script.is_absolute():
        script = ROOT / script
    script = script.resolve()
    if not script.is_relative_to((ROOT / 'tools').resolve()):
        raise RuntimeError('Invalid conversion script')
    sys.path.insert(0, str(script.parent))
    sys.argv = [str(script), *args]
    runpy.run_path(str(script), run_name='__main__')
    return 0


FROM_DISC = ['default.xex', 'data/anim', *REQUIRED]


def convert(xex, out):
    xex = xex.resolve()
    if xex.suffix.lower() == '.iso':
        import xiso
        out = out.resolve()
        out.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='skategm-disc-', dir=out.parent) as disc:
            print('Reading the files it needs from your disc image', flush=True)
            try:
                xiso.extract_files(xex, FROM_DISC, disc, lambda text: print(text, flush=True))
            except xiso.XisoError as error:
                raise RuntimeError(f'{xex.name}: {error}. Is this a Skate 3 (Xbox 360) disc image?')
            return convert_game(Path(disc), out)
    if xex.name.lower() != 'default.xex' or not xex.is_file():
        raise RuntimeError(f"Select default.xex from an extracted Skate 3 (Xbox 360) game folder, or the game's .iso, not {xex.name}.")
    return convert_game(xex.parent, out)


def convert_game(game, out):
    missing = [path for path in REQUIRED if not (game / path).is_file()]
    if missing:
        raise RuntimeError('This folder is missing Skate 3 game data (' + ', '.join(missing) +
                           '). Keep the data folder beside default.xex.')

    from tools.asset_pipeline import asset_exports as exports

    out = out.resolve()
    stage = out.with_name(out.name + '.partial')
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)

    def report(text):
        print(text, flush=True)

    with tempfile.TemporaryDirectory(prefix='skategm-convert-', dir=stage.parent) as work, \
            (stage / 'conversion.log').open('w', encoding='utf-8') as log:
        work = Path(work)
        converted = exports.core(game, stage, work, report, log)
        exports.character(game, stage, work, report, log, converted)

    assets = stage / 'assets'
    for needed in ('private/skater.glb', 'private/game.json', 'private/stock/physics-skeletons.json',
                   'private/stock/skater-collections.json'):
        if not (assets / needed).is_file():
            raise RuntimeError(f'Conversion finished without {needed}.')
    shutil.rmtree(out, ignore_errors=True)
    stage.rename(out)
    report('Skate 3 data ready')


def main():
    if len(sys.argv) > 2 and sys.argv[1] == '--task':
        return run_task(sys.argv[2], sys.argv[3:])
    parser = argparse.ArgumentParser()
    parser.add_argument('--xex', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    try:
        convert(args.xex, args.out)
    except Exception as error:
        traceback.print_exc()
        print(f'ERROR: {error}', flush=True)
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
