# Third-party notices

This source tree does not contain Electronic Arts game data. Files generated
from a user's legally owned Skate 3 disc stay in Git-ignored directories.

## Universal Texture Tool parser

The source files under `tools/vendor/utt` are from UTT 1.1.7 by duckyinnit and
are distributed under the MIT License. The complete license text is retained
at `tools/vendor/utt/LICENSE`. No bundled third-party executables from UTT are
included.

## University conversion and BIG archive tools

The relevant source is from the Skate 3 Custom Engine Layer at commit
`0dafeb138973d48f67c7be6df1d9f9d6e7c3c5a4`. It is distributed under the MIT
terms retained at `tools/vendor/university/LICENSE-PROJECT.md`. That license
does not cover retail game data or upstream projects.

## XboxDev extract-xiso

The setup script downloads the unmodified Windows release of
[XboxDev/extract-xiso](https://github.com/XboxDev/extract-xiso) directly from
its official GitHub release and verifies its SHA-256 before execution. The
binary is cached only in a Git-ignored local work directory and is not
distributed by this repository.

## Skate 3 animation toolkit sources

The ABIN/RX2 scripts under `tools/vendor/skate3_anim` are pinned from
[chasmlol/skate-3-trick-toolkit](https://github.com/chasmlol/skate-3-trick-toolkit)
at commit `85d9d679bc35462ce66fdbba95007b56a94579f0`. They are included so owned-disc
setup is reproducible and does not depend on an external checkout.
