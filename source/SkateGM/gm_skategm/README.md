# gm_skategm - Skate 3 simulation as a Garry's Mod binary module

Milestone 1. Runs the real Skate 3 simulation (`skate-host` from the IW4L
mashup, built on SK8-ENGINE/skate-3-rust-engine) inside Garry's Mod.
No Skate 3 code or data is included here: the engine source comes from the
mashup repository, and the game data from your own copy of Skate 3.

Lua API (after `require("skategm")`): `skategm.Load/Activate/Step/Poll/Stop/Version`,
documented at the top of `src/lib.rs`.

## Build (Windows, Garry's Mod x86-64 branch)

Folder layout (both folders side by side):

    C:\sk8build\
        2010-rust-rewrite-mashup\     git clone https://github.com/chasmlol/2010-rust-rewrite-mashup
        gm_skategm\                       this folder

Then, in a terminal inside `gm_skategm`:

    cargo build --release

Output: `target\release\gmcl_skategm_win64.dll` -> copy to `garrysmod\lua\bin\`.

`Cargo.lock` pins exactly the dependency versions the mashup's release uses.
The first build downloads and compiles Bevy, which takes several minutes.

Troubleshooting build: `cargo build --release --no-default-features` makes a
stand-in DLL that fakes a skater without the engine or game data, to test the
Lua side on its own.
