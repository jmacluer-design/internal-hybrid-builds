# Skate 3 Bevy preservation project

An independent, source-only Rust/Bevy reconstruction of Skate 3's skating,
animation, and world systems. The goal is evidence-backed behavioral parity,
not a generic skateboarding prototype.

This is an early work in progress. Current systems include riding, pushing,
carving, Flickit anticipation and tricks, landing quality and friction,
powerslides, manuals, fakie stance, grabs, off-board locomotion, transition
physics, grinding foundations, and an extracted University world pipeline.

## Important legal boundary

This repository contains no Skate 3 ISO, executable, title update, retail
animation bank, character model, texture, or extracted University data. It is
not affiliated with or endorsed by Electronic Arts.

You must dump your own legally owned Xbox 360 copy and generate the ignored
local assets. Do not upload or redistribute those generated files. See
[Setup from legally owned game data](docs/SETUP_FROM_OWNED_GAME.md).

## Quick start

Install the prerequisites in the
[owned-game setup guide](docs/SETUP_FROM_OWNED_GAME.md), then clone the
repository and drag your legally dumped Skate 3 Xbox 360 ISO onto
`SETUP FROM OWNED ISO.bat`. You can also run it directly:

```powershell
git clone https://github.com/chasmlol/skate3clone.git
cd skate3clone
.\SETUP FROM OWNED ISO.bat "D:\OwnedBackups\Skate 3.iso"
```

That one command downloads a pinned, hash-verified open-source ISO extractor,
extracts the required files from your ISO, builds the retail skater and
animation bank, converts University with its textures, collision, and grind
data, runs the tests, compiles the game, and launches it. It does not require
`Skate3Research`, SK8, RPCS3, or a separately cloned animation toolkit.

The first asset build is intentionally substantial because Blender generates
the complete local animation bank. Later launches and Cargo builds are
incremental:

```powershell
.\LAUNCH LATEST MAIN.bat
```

For a no-window verification:

```powershell
.\LAUNCH LATEST MAIN.bat --headless
```

Those are the only two root launchers in the public distribution:
`SETUP FROM OWNED ISO.bat` performs first-time setup, and
`LAUNCH LATEST MAIN.bat` handles every later run. Old per-feature test
launchers and local reverse-engineering wrappers are intentionally excluded.

## Controls

- Xbox left stick or `A` / `D`: move, steer, and carve
- Xbox `A` or `Space`: regular push
- Xbox `X` or left `Shift`: mongo push
- Xbox right stick or arrow keys: Flickit input, trick windup, and manuals
- Xbox `LT` / `Q`: left-hand grab
- Xbox `RT` / `E`: right-hand grab
- Both triggers: two-hand grab
- Xbox `B` or `Circle`: footbrake
- `Y` or `Triangle`: mount or dismount
- `R`: reset

## Development principles

- Retail behavior is recovered from synchronized telemetry, decoded RX2/ABIN
  animation data, state/action XML, native-code analysis, and deterministic
  replay fixtures.
- Proven behavior, bounded inference, unresolved behavior, and human visual
  verification are kept distinct.
- Retail-derived outputs stay under ignored private directories.
- The simulation runs at 120 Hz and keeps gameplay translation separate from
  authored animation roots.

The source distribution includes the required permitted conversion code.
Provenance and upstream licenses are recorded in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The companion
[Skate 3 trick toolkit](https://github.com/chasmlol/skate-3-trick-toolkit)
remains useful for independent research, but it is not a setup dependency.

## Repository layout

```text
src/          Bevy simulation, animation, camera, character, and world code
tools/        owned-game extraction, conversion, validation, and launch tools
parity/       source-controlled replay fixtures and custom parity maps
research/     recovered specifications and source-safe evidence
docs/         subsystem evidence and setup documentation
assets/       source-safe custom assets; assets/private is ignored
```

## Contributions and license

Issues and research-backed pull requests are welcome. Please do not attach
retail game files or converted retail assets.

No software license has been granted yet. Public visibility does not grant
permission to copy, redistribute, or create derivative works beyond rights
provided by applicable law.
