# TU3 grab animation adapter

## Scope

This pass inventories every animation resource emitted by
`src/grab_graph.rs` and establishes a hard boundary between retail MotionGraph
resources, physical TU3 ABIN leaves, and actions actually exported in the
current Bevy GLB. It does not infer a blend tree from similar clip names.

## Pinned sources

| Artifact | SHA-256 |
|---|---|
| `Skate3Extracted/data/anim/OnBoard.abin` | `30AA324D6D7C51C325D53E9268C1AD91783B0154D21BBEF5DC5A61EAE8333BD7` |
| `research/animation/reports/skate3_onboard_clips.csv` | `7B2041D3E8FC305D589A05B65B72B5181319197B4CF4FC6C410C8BDDAA131D10` |
| `assets/private/skater_push.manifest.txt` | `B5578A493A9432685A98179085655D787E3D82B48E8A649BC41998C672FDE56F` |
| `assets/private/skater_push.glb` | `50FD4FF6300A7EA49B135E6B1AD110EB9101CC4472B87471C87358FB90B14EE3` |
| `src/grab_graph.rs` | `7F73448393595C5A50756933CCED343ABF33ACA6A812C7D7F2BB0DA21B7879BC` |
| `MotionGraphIncludes/air.xml` | `672871717605A2AD6D592FD24C5270E462493507B01EBF5F7D443B8494B2F7F0` |
| `GrabsTweaks/T_FSBSGrab.xml` | `4E499BFC027D414CA3C2C9CAF7F2D6BF378168D84666C68521361B41F5D2589F` |
| `GrabsTweaks/DBLGrab.xml` | `95B2BD0170C81B1CD11CF8DD158DC02BB0FCA694FDC0EA35394348736804A88F` |
| `GrabsTweaks/T_MuteStaleGrab.xml` | `042FE27BB156A749D428A745513A64F545BB3360122FA4E4DE2DFD23201C215A` |
| `GroundGrabs/Coffin.xml` | `438F60612E0566DE1B49E35DAE6F334746C8C38B5512CF8DA657A88442541277` |
| `GrabsTweaks/Superman.xml` | `86C551BF0F66ADA9D4BC425A41986EC9B4453000F8EA93BC4C4375EA3A5A9BEB` |
| Wave 2 telemetry patch source | `7D5D4D8B4EF299CE8025711FC0B3F1FFEC9109B15617A7F52B4739A12312A2E0` |

## Coverage

`GrabRuntime::animation_request` currently emits 24 unique resources:

- 16 names are exact physical leaves in the authoritative OnBoard catalog.
- 8 are virtual MotionGraph resources.
- 24 of 24 are classified by `GRAB_GRAPH_RESOURCES`.
- 0 of the 16 physical leaves are present in the pinned 243-action Bevy GLB.
- No current runtime capture contains selected-leaf events for these grabs.

The direct physical set covers FS/BS/double Into and Out, FS/BS-to-double and
double-to-FS/BS transitions, mute/stale Into, Coffin Into, and all three
Superman phases. `PHYSICAL_GRAB_CATALOG` retains the exact ABIN index, frame
count, 30 Hz sample rate, eight-part count, block offset, and block size.

## Virtual resource contracts

| Virtual resource | Observed inputs | Current result |
|---|---|---|
| `BLEND_FS_TWEAK2` | filtered `tweak_x`, `tweak_y` | missing selected-leaf/blend definition |
| `BLEND_BS_TWEAK` | filtered `tweak_x`, `tweak_y` | missing selected-leaf/blend definition |
| `BLEND_DBL_TWEAK` | filtered `tweak_x`, `tweak_y` | missing selected-leaf/blend definition |
| `BLEND_MUTE_TWEAK` | filtered `tweak_x`, `tweak_y` | missing selected-leaf/blend definition |
| `BLEND_STALE_TWEAK` | filtered `tweak_x`, `tweak_y` | missing selected-leaf/blend definition |
| `B_MUTE_OUT` | none passed by `PlayAnimation` | missing exit selector |
| `B_STALE_OUT` | none passed by `PlayAnimation` | missing exit selector |
| `B_COFFIN` | none passed by `PlayAnimation` | missing Coffin selector |

The XML proves that the five tweak resources consume unnormalised values from
the two `FilterMotionGraphIntent` behaviours. It does not contain the resource
definitions or their physical leaf/weight topology. The ABIN contains
name-similar cycle and exit leaves, but similarity is not a mapping.

## Adapter behavior

- `resolve_grab_request` resolves only exact physical ABIN names.
- A direct resolution contains one physical leaf with weight `1.0`.
- Local seek time, graph transition time, playback speed, repeat state, and
  `applyPosture` are transported without creating a second clock.
- Invalid or negative timing is rejected.
- Virtual resources validate their typed parameter contract and then return a
  missing-evidence failure.
- `adapt_grab_for_bevy` additionally rejects a proven physical ABIN leaf until
  that exact action is present in the pinned GLB manifest.
- The public Bevy-ready type has no constructor that accepts a raw resource
  name, preventing `B_*` and `BLEND_*` leakage.

## Required captures

1. Export the 16 directly named physical leaves into the Bevy GLB and update the
   pinned manifest/hash.
2. Run synchronized neutral, cardinal, diagonal, and boundary tweak captures
   for FS, BS, double, mute, and stale grabs with selected-leaf telemetry.
3. Record selected leaf, normalized/local time, playback speed, all leaf
   weights, transition duration, filtered `tweak_x`/`tweak_y`, stance, and
   handedness on the same retail frame.
4. Capture `B_MUTE_OUT` and `B_STALE_OUT` across the relevant air/landing timing
   boundaries.
5. Capture `B_COFFIN` at neutral and directional input, including Coffin exit
   hand arbitration.

Until those captures exist, the adapter deliberately reports typed missing
evidence rather than selecting a plausible clip.
