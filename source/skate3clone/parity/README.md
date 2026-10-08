# Skate 3 parity workflow

This directory is the acceptance boundary for the project. A feature is not
called 1:1 because it looks plausible or because a replacement implementation
passes its own tests. It becomes a locked parity checkpoint only after the
retail evidence, deterministic machine checks, and the owner's visual verdict
all agree.

## Evidence labels

- `retail_static`: exact data recovered from TU3 assets, XML, symbols, or
  disassembly.
- `retail_runtime`: values or matrices captured from the deterministic Skate 3
  harness while replaying the checkpoint input.
- `derived_exact`: a lossless conversion whose output is numerically compared
  with its retail source.
- `candidate`: an implementation supported by evidence but not yet compared
  against the complete retail runtime output.
- `human_verified`: the owner accepted the named build and replay visually.
- `unknown`: the retail behavior or value has not been recovered. Unknowns
  block a checkpoint from being labelled parity-complete.

Calibrated, aesthetically chosen, or guessed constants must be listed as
`unknown`; they cannot silently enter a locked checkpoint.

## Checkpoint loop

1. Define one narrow behavior and its deterministic retail/Bevy input replay.
2. Hash every retail source, extracted asset, tool, and Bevy source file used.
3. Capture retail animation IDs, state transitions, SkeletonIK inputs/outputs,
   selected final bone matrices, board transforms, and timing.
4. Reproduce the same checkpoint in Bevy.
5. Compare matrices and timing numerically. Keep unknown fields visible.
6. Run `tools/run_parity_checkpoint.ps1`.
7. Launch the generated build for owner verification.
8. Record `accepted` or `rejected` in `human-verdict.json`, with the exact run
   manifest and screenshot/video references.
9. Only an accepted run with no scoped unknowns is moved to `locked/`.

The existing Skate 3 harness at
`C:\Users\Daddy\Documents\Skate3Research\harness` remains the deterministic
retail oracle. Its named-pipe replays are preferred over keyboard automation.
The already recovered authoritative final character palettes in
`Skate3CustomEngineLayer\src\native\skate3_native_palette.cpp` are the source
for future named-bone pose captures; checkpoint tooling should map those rows
through the RX2 skeleton rather than infer pose from screenshots.

## Current sequence

1. `CP001-idle-push-foot-contact`: neutral body/board registration and both
   animated OnBoard toe targets through regular and mongo pushes.
2. `CP002-push-input-and-sequencing`: tap/hold intent, native-speed hard-push
   leaves, and stale-loop-free sequence behavior.
3. `CP003-flat-ground-onboard-locomotion`: measured carve/brake/powerslide
   controller, complete scoped motion leaves, board articulation, toe-target
   IK, stationary idles, and deterministic capture trace.
4. Runtime `ApplyingBodyTilt` attributes and complete `SetTurning` output
   matrices.
5. Powerslide animation attributes, SkateboardBody contact matrices, slopes,
   surface parameters, pumping, kickturn/revert, switch stance, and camera.

## Matched SK8 / Bevy parity takes

For persistent frame-by-frame control of both live games, use
`RUN DUAL ORACLE.bat`; the protocol and recorder are documented in
`DUAL_ORACLE.md`.

For the normal end-to-end workflow, double-click
`RUN FULL PARITY TEST.bat` in the project root. Press F9 in the first Bevy
window to start a short take and F9 again to stop it. The launcher then runs
the same take in SK8, replays it deterministically in Bevy, captures movement
and final-bone telemetry, closes the SK8 instance it started, creates both
comparison reports, and opens the completed run folder. No file dragging or
manual command sequence is required. SK8 intentionally remains still for
about 30 seconds after its map appears while the native bone recorder arms;
the recorded movement then plays once.

The shared comparison fixture is generated from one Blender scene:

- `shared-map/skate_parity_grid.blend` is the authoring authority.
- `shared-map/skate_parity_grid.skate` is copied into preview 18's `maps`
  folder.
- `../assets/parity/skate_parity_grid.glb` is loaded by Bevy.

Both exports contain one 200 m square surface, one repeated 10 m / 1 m grid
texture, two visual triangles and two collision triangles. There are no
obstacles, grinds, doors, lights, routes or spawned objects.

## Synchronized FFmpeg visual review

Run the same saved replay through both visible game windows and build aligned
review videos with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_visual_parity_capture.ps1 `
  -Replay parity/replays/full-charge-ollie.json
```

The visual runner records SK8 and Bevy sequentially at 60 fps and 1280x720.
SK8 begins recording immediately before its named-pipe queue is submitted.
Bevy uses `SKATE3_PARITY_START_GATE`, so its replay and telemetry clock remain
stopped until FFmpeg has produced its first frame. The generated run contains:

- raw SK8 and Bevy window recordings;
- a flick/input-aligned side-by-side video, preserving timing differences;
- first-air and apex-aligned side-by-side videos for pose comparison;
- first-air overlay and absolute-pixel-difference videos;
- paired frames at flick, first air, apex, and touchdown;
- raw telemetry, capture offsets, hashes, and an alignment report.

SK8 is always the left panel and Bevy the right panel. Camera, lighting, and
rasterization differences remain visible in the overlay/difference outputs,
so those files are diagnostic aids rather than automatic parity verdicts.
The owner still records the final visual verdict. Add `-IncludeBoneCapture`
when the same run also needs the slower native palette recorder.

The individual launchers below remain available for debugging a specific
stage:

1. Run `tools/Record New Parity Take.cmd`.
2. Press F9 in Bevy, perform one short flat-ground scenario, then press F9
   again. The take is written below `parity/dual-runs`.
3. Drag the take's `input-replay.json` onto `tools/Replay In SK8.cmd`. The
   launcher loads the shared `.skate` map, sends the exact 60 Hz controller
   poll sequence through `Skate3InputLab`, and records frame-numbered board
   position/orientation plus internal observation state. It also waits for
   the release's native BSIG1 recorder, so the replay starts after an
   approximately 30-second instrumentation arm delay.
4. Drag the same replay onto `tools/Replay In Bevy.cmd`. Bevy records a clean
   deterministic 120 Hz replay trace.
5. Run
   `tools/compare_parity_run.ps1 -RunRoot <the take folder>`. The report uses
   each board's starting local frame and writes `comparison.json` plus
   `comparison.md`. When both bone streams are available it also writes
   `bone-comparison.json` and `bone-comparison.md`.

Bevy records all 33 named rider/board joints after animation, board
articulation, SkeletonIK, and transform propagation. SK8 decoding retains its
native BSIG1 palettes exactly. Preview 18 currently emits 84-row mesh-local
render palettes; these remain raw evidence and are not relabelled as named
joints until the retail mesh-remap/bind mapping is verified. A movement report
is still completed, while the unavailable named-bone comparison is reported
as such rather than guessed.

Keep takes short and isolate one behavior per take: single hard push, held
push, steady carve, carve reversal, brake, or powerslide. The SK8 input lab
supports 1,024 run-length encoded state steps. Visual success/failure remains
the human checkpoint; telemetry provides the numerical diagnosis.
