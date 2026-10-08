# Park parts

Ramps, rails and boxes you spawn from **Entities > SkateGM**. Each part is one
Lua file in `lua/skategm_parts/parts/`. The framework (`lua/skategm_parts/sh_parts.lua`)
turns its shape into four things at once:

- the mesh you see;
- GMod physics, so players walk on it, physgun it and freeze it;
- the skate engine's collision, sent as one clean outer surface with no hidden inside faces;
- a spawn menu entry.

The engine then treats it like any solid prop: its edges become grindable,
and its feet get smooth transitions into the ground.

To add a part from another add-on, put a file at `lua/skategm_parts/parts/<id>.lua`
in your own add-on (Garry's Mod merges the `lua/` folders of all add-ons).

```lua
local P = SKATEGM_PARTS
P.Register({
	id = "bank", title = "Bank ramp", order = 20, surface = "concrete",
	info = "A long, gentle bank.",
	pieces = function()
		-- a profile in the x-z plane (x = the way you ride into it), pushed
		-- 128 units across in y
		return { P.Prism("y", { { 0, 0 }, { 128, 0 }, { 128, 32 } }, 0, 128) }
	end,
})
```

Sizes: a family registers one part per size from one builder (the size
without a `key` keeps the family's own id):

```lua
P.Family({
	id = "deck", title = "Deck", order = 20, category = "SkateGM Platforms",
	sizes = { { key = "48x128", title = "48 high, 128 wide", h = 48, w = 128 }, ... },
	build = function(s) return { P.Box(0, 0, 0, 128, s.w, s.h) } end,
})
```

## The park editor

Parts snap together where they're spawned or let go of with the physgun
(`skategm_parts/sv_park.lua`). Each side of a part's footprint is a
connector (`P.Connectors`), at the height of the part's top along that side:
a ramp's foot is 0, a quarter pipe's deck edge its height. A dropped part
joins the nearest other part whose side faces it at the same height, within
40 units (`P.SnapPlacement`): flush, centred and squared up. With nothing to
join, the player's grid and turn steps apply (`skategm_parts_snap`,
`skategm_parts_grid` - Settings > Advanced on the controller - and
`skategm_parts_turn`, per player). Whole parks are saved and loaded from the
park editor's Park page; the console commands `skategm_park_save` / `_load` /
`_list` / `_clear` (host and admins; files in `data/skategm/parks/`) stay. Parts from other add-ons snap too: their connectors
come from their shape.

The controller park editor (`skategm_parts/cl_editor.lua` + `sv_editor.lua`):
LB + B while skating flies a free camera (others see a watermelon with a
glowing eye, relayed through the server at 10 Hz). X: parts menu by
category, A: place, Y: pick up / move, D-pad left/right: turn 15 degrees,
up: snapping on/off, down: remove, B: cancel, RB: fast, LB + B: back on the
board under the camera. The client works out the snapped placement with
`P.Place` (the same function the physgun's snap uses, with a 72-unit reach
in the editor) and the server checks and does it: `skategm_park_editor`
(0/1/2 = off/everyone/admins), `skategm_park_editor_shared`, at most 300
parts, other add-ons' `PlayerSpawnSENT` hooks, its own sandbox limit
(`sbox_maxskategm_parts`, 300), undo. The editor's Park page saves and loads
through Garry's Mod's own saves (`skategm_parts/cl_saves.lua`: `gm_save`,
this map's `saves/*.gms`, the Workshop's saves tagged with this map, loaded
with `gm_load`); the JSON `skategm_park_save` / `_load` console commands stay
(optional `x y z yaw` origin).
Tests: tests/lua/park_editor_test.lua (client), park_editor_sv_test.lua.

The add-on ships an empty map to build in, `sgm_warehouse` (a 6144 x 4096
warehouse, 640 high, one flat concrete floor, skylights). It's generated:
`python tools/make_warehouse.py` writes `maps/src/sgm_warehouse.vmf` and
compiles it with Garry's Mod's own vbsp / vvis / vrad into
`addon/skategm/maps/` (stock HL2 textures only).

Pieces:

| helper | makes |
|---|---|
| `P.Prism(axis, profile, from, to, surface, convex)` | a profile pushed along `axis` ("y": profile in x-z; "x": profile in y-z). Concave profiles need `convex`, a list of convex pieces covering it, for GMod physics |
| `P.Box(x0, y0, z0, x1, y1, z1, surface)` | a box |
| `P.Pipe(axis, from, to, cu, cv, radius, surface)` | a round bar (rails, coping) |
| `P.CurveUp(x0, x1, height, power, steps)` | points of a ramp curve rising from the ground |
| `P.QuarterCurve(x0, radius, steps)` | points of a quarter-pipe transition |
| `P.UnderCurve(points)` | the convex slabs under a curve, for `convex` |

Surfaces: `concrete`, `wood`, `metal`, `paint` (add your own to `SKATEGM_PARTS.SURFACES`).
Parts are centred on their footprint and sit on the ground where you aim. They
spawn frozen and facing the way you look, so you ride into them along their +x.

Check a new part with `tests/lua/parts_test.lua`: every part must be a closed,
outward-facing mesh, because the engine treats any stray face as a wall. Then
ride it with the real engine: `harness/parts.lua` places each part on clear
ground in front of the skater and rides into it.
