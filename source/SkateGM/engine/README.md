# The skate engine

The Skate 3 physics, animation and trick engine SkateGM runs, as Rust source.

**From:** [2010 Rust Rewrite Mashup](https://github.com/chasmlol/2010-rust-rewrite-mashup)
by chasmlol, its `skate/` folder (`Cargo.toml` and `crates/`) at commit
`65d9e117bdec651146e4fe26a903893b4b86e486`. Those crates came to the mashup
from [SK8-ENGINE/skate-3-rust-engine](https://github.com/SK8-ENGINE/skate-3-rust-engine)
(commit `cb79689`).

**Licence:** Apache-2.0, as the mashup: [`LICENSE`](LICENSE). The mashup's own
notice is kept as [`NOTICE-mashup`](NOTICE-mashup).

**What's here:** source code only. No Skate 3 or EA code, data or assets: the
engine reads the player's own converted copy of the game at run time (see the
exporter in `../exporter/`).

**Our changes:** marked in the source with `gm_sk8 addition` comments, and
collected as one diff against the commit above in
[`CHANGES.patch`](CHANGES.patch) (`python tools/engine_patch.py <clone>`
rewrites it). They add what Garry's Mod needs:
- read-only access to scoring, the session marker and the triggers;
- a camera-shake switch;
- a pushed velocity (the rocket board, testing boosts);
- returning to the checkpoint on demand, slightly above the recorded spot
  (falling into water);
- recovering from a tick that failed part-way;
- masking pad buttons (the unported airborne dismount);
- the moving collision layer (`BoardWorld::set_moving`,
  `Session::set_moving_collision`) for other players and moving props.
- carrying the skater on moving and turning platforms;
- the bail's left stick read through the camera, as on foot;
- the rocket allowed while powersliding and reverting;
- the unported air dismount step skipped instead of failing the tick.
