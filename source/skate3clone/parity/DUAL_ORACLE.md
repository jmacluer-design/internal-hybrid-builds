# Dual-game oracle

`RUN DUAL ORACLE.bat` starts the current instrumented SK8 build and the Bevy
port on the shared parity map. Both remain open. The launcher injects one raw
XInput-shaped state into both engines, pauses them at completed retail-frame
boundaries, and records paired snapshots under `parity/oracle-runs`.

Before the first pause, the launcher requires eight distinct SK8 native frames
with valid board and skater transforms, a valid board state, `on_ground=1`,
and `in_air=0`. Endpoint availability alone is not gameplay readiness. This
gate prevents the oracle from freezing the native skater during the owned-map
spawn fall, when the board and skater transforms can still be misaligned.

The instrumentable local SK8 branch reads SKATE packages through v8, while
the newer official binary's copy of this map is v15. The launcher therefore
uses `parity/oracle-map/skate_parity_grid.skate`, rebuilt from the same
`tools/build_parity_grid.py` geometry/material source with the local v8
exporter. It does not substitute a different course.

One oracle frame is exactly one normalized Skate 3 input frame:

- SK8 advances one recovered 60 Hz guest frame.
- Bevy advances the corresponding two 120 Hz fixed simulation substeps.
- `ORACLE STEP` does not reply until the requested frame is complete and the
  engine is stopped at the next boundary.

The mirrored protocol is:

```text
PING
STATUS
CAPSULE_SNAPSHOT
SET REPLACE buttons,lt,rt,lx,ly,rx,ry
DISABLE
ORACLE PAUSE
ORACLE STEP <1..3600>
ORACLE RUN
ORACLE STATUS
```

SK8 listens on the local named pipe `\\.\pipe\Skate3InputLab`. Bevy listens
only on `127.0.0.1:38473`. Neither endpoint needs its game window to have
focus.

The interactive launcher supports `step`, raw `pad`, `neutral`, `push`,
`steer`, `snapshot`, `run`, `pause`, `live`, `status`, and `quit`. `live`
returns both applications to physical-controller input. This is useful for
human feel checks; exact parity experiments should use lockstep commands so
both engines consume the identical packet for the identical frame count.

The same controller is scriptable without the prompt. For example:

```powershell
.\tools\dual_oracle.ps1 -Action Pad -Buttons 4096 -NoLaunch
.\tools\dual_oracle.ps1 -Action Step -Frames 12 -NoLaunch
.\tools\dual_oracle.ps1 -Action Neutral -NoLaunch
```

`CAPSULE_SNAPSHOT` intentionally exposes verified, readable state rather than
arbitrary process memory. SK8 currently publishes player-owned board
transform and lifecycle state. Bevy additionally publishes movement,
animation, push, lean, wheel, and action-layer state. More recovered retail
fields can be added to the same versioned response as their ownership and
meaning are verified.
