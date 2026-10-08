# Setup from a legally owned Skate 3 ISO

The public repository is source-only. It contains all permitted conversion
scripts needed by the game, but no Skate 3 executable, ISO, animation, model,
texture, or map data.

## Requirements

- Windows 10 or 11
- Git
- [Rust stable with Cargo](https://rustup.rs) and the Windows MSVC build
  tools selected by the Rust installer
- Python 3.11 or newer, with `python.exe` available on `PATH`
- Blender 5.x, installed normally or available through
  `BLENDER_EXECUTABLE`
- At least 30 GB of free disk space for the extracted disc, converted assets,
  University build intermediates, and Rust build cache
- A legally dumped Xbox 360 Skate 3 base-game ISO matching the supported
  retail revision
- An Xbox-compatible controller

You do not need `Skate3Research`, SK8, RPCS3, a title-update download, a
separate map toolkit, or a separate animation-toolkit checkout.

## One-command setup

Clone the repository:

```powershell
git clone https://github.com/chasmlol/skate3clone.git
cd skate3clone
```

Drag your ISO onto `SETUP FROM OWNED ISO.bat`, or run:

```powershell
.\SETUP FROM OWNED ISO.bat "D:\OwnedBackups\Skate 3.iso"
```

The setup performs the complete local build:

1. Downloads the pinned official
   [XboxDev/extract-xiso](https://github.com/XboxDev/extract-xiso) Windows
   release and verifies its SHA-256 before use.
2. Extracts the supplied ISO into the ignored local `runtime` directory.
3. Validates the exact supported retail BIG archives and extracts only the
   required inputs.
4. Builds the textured default skater and complete animation bank in Blender.
5. Builds the manual animation bank.
6. Converts University, including textures, lightmap data, collision, and
   grind rails, into Bevy's ignored local cache.
7. Runs the Rust tests, compiles the game, and launches University.

The script installs the small Python `numpy` and `Pillow` dependencies for
the current Windows user if they are absent. All generated retail content
stays beneath Git-ignored directories in your clone.

The initial conversion can take a while because thousands of authored
animations and the complete University map are processed. This is a one-time
asset-generation cost, not a full rebuild on every launch.

## Later launches

After setup completes, use:

```powershell
.\LAUNCH LATEST MAIN.bat
```

Cargo and the private-asset verification path are incremental. To verify the
build without opening a game window:

```powershell
.\LAUNCH LATEST MAIN.bat --headless
```

## Supported retail data

The converter deliberately fails closed if the supplied disc is a different
revision, region, modified dump, or damaged extraction. The supported
base-disc archive baselines are:

| Archive | Size | SHA-256 |
| --- | ---: | --- |
| `data\big\miscload.big` | 44,920,384 | `3673FDC0CA3B6DAA72260350DD9263F068EC5999D9604B3C11BFE4F4248942EC` |
| `data\content\createacharacter.big` | 472,328,128 | `B87E9E01D446DF37D707D0F2AC2AB872BAF29BBA91EEAE5FD08997C7D475D4EB` |
| `data\content\worldDIST_University.big` | 798,165,184 | `37D6A4517BD0A5E25F493F18409EDFBD3B3D74229F12F1AB6C15598AA3240091` |

Do not bypass these checks. They prevent a mismatched animation/map build
from appearing to succeed.

## Troubleshooting

`Python 3.11 or newer is required`
: Reinstall Python from python.org and enable its **Add Python to PATH**
  option.

`Rust/Cargo is required`
: Install Rust from rustup.rs, close and reopen the terminal, then rerun the
  setup BAT.

`Blender 5.x is required`
: Install Blender normally. For a portable copy, set
  `BLENDER_EXECUTABLE` to its full `blender.exe` path before running setup.

`hash mismatch` or `No supported retail archive`
: The ISO is not the supported clean base-disc revision, or the dump is
  damaged. Use a clean dump of your own disc.

`animation bank ... expected ...`
: A previous setup was interrupted or belongs to an older checkout. Rerun
  the ISO setup after updating the repository.

No technical research layout or environment variables should be needed for
the normal setup path. If setup fails for another reason, keep the complete
error output when reporting it.

## Legal and publishing boundary

The ISO and every generated retail-derived asset are ignored by Git. Do not
redistribute an ISO, XEX/XEXP, BIG, ABIN, RX2, generated retail GLB, extracted
texture, map cache, or other copyrighted game data.

Before contributing, run:

```powershell
python .\tools\audit_public_tree.py
```
