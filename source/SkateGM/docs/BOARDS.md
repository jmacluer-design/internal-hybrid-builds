# Writing a board type

A board type is what a player picks from the **Board type** row of the
controller's **Settings > Board** page (LB + A; the row shows once there's
more than one). The mod comes with one, and an example sits next to this file;
both use the framework described here:

- `lua/skategm_boards/classic.lua`: the built-in skateboard (colours, image under the deck)
- `docs/example_board/lua/skategm_boards/model.lua`: any model, with scale and
  offset sliders (a complete example; copy it into your own add-on to use it)

Every `.lua` file in `lua/skategm_boards/` is loaded on both server and client,
so the easiest way to add a type is to put one file in your own add-on at
`lua/skategm_boards/<yourtype>.lua`. Garry's Mod merges the `lua/` folders of
all add-ons, so the mod picks it up with no other setup.

## What the framework does for you

- puts your type in the dropdown and shows your options when it's picked;
- makes a saved client convar for each option and resends the player's board
  when one changes;
- sends the options to everyone, with every value checked against your rules
  on the server (numbers clamped, model paths validated, unknown keys dropped);
- falls back to the built-in skateboard if your draw function fails or another
  player doesn't have your type installed.

These settings stay shared by every type: rocket board, hoverboard mode, and the rolling and
rocket sounds.

## A complete example

```lua
-- lua/skategm_boards/glow.lua
local GLOW = BOARD.RegisterType({
	id = "glow",              -- letters, digits, _
	title = "Glow board",     -- shown in the dropdown
	order = 10,               -- 1 = skateboard, 2 = any model
	fields = {
		{ key = "size", kind = "number", convar = "glowboard_size", min = 1, max = 20, default = 8, decimals = 1, label = "Glow size" },
		{ key = "pulse", kind = "bool", convar = "glowboard_pulse", default = true, label = "Pulse" },
	},
})

if not CLIENT then return end

function GLOW.draw(ctx)
	local o = ctx.opts
	local size = o.size * (o.pulse and (1 + 0.2 * math.sin(RealTime() * 4)) or 1)
	render.SetColorMaterial()
	render.DrawSphere((ctx.P.TRUCK_FRONT + ctx.P.TRUCK_BACK) / 2, size, 12, 12, Color(80, 255, 200, 120))
	ctx.DrawBoard(ctx.P, { graphic = ctx.graphic, rocket = ctx.rocket, trucks = not ctx.hover })
	return true
end
```

Settings > Board gets one row per field (numbers and choices change with
D-pad left / right, on/off toggles, colours pick from a palette; `model` and
`string` fields are set from the console with their convar). Add
`function GLOW.rows(List)` returning extra rows (built with `List.Choice`,
`List.Bool`, `List.Number`, `List.Colour` from skategm_ui/cl_pad.lua) for
anything more; the example board uses it for its list of models.

## Fields

| kind | value | extra keys |
|---|---|---|
| `number` | clamped to min..max | `min`, `max`, `default`, `decimals` |
| `bool` | true / false | `default` |
| `choice` | index into `choices` | `choices` (strings or `{ label, ... }`), `default` |
| `model` | a `models/...mdl` path, or `default` | `default` |
| `string` | up to `max` characters (64) | `max`, `default` |

Any field can take `showWhen = { "<key>", <value> }`: its row is only shown on
the Board page while that choice field is set to that value (the effects' colour
rows use `showWhen = { "mode", 3 }`, shown for "Custom colour").

Pick convar names that won't clash with another add-on's (prefix them with your type id).

## draw(ctx)

Called every frame for each skater using your type. Return `true` when you drew
something; `false` (or an error) draws the built-in skateboard instead.

| ctx | |
|---|---|
| `ply` | the player |
| `P` | the engine's bone positions this frame (`TRUCK_FRONT`, `TRUCK_BACK`, `RIGHT_WHEELFRONT`, `LEFT_WHEELFRONT`, `RIGHT_WHEELBACK`, `LEFT_WHEELBACK`, `HIPS`...), already lifted in hoverboard mode |
| `opts` | your fields' values for this player |
| `look` | the shared look: `deck`, `wheels` (colours), `mat` (deck image) |
| `graphic` | the player's colour |
| `rocket`, `hover` | the shared switches |
| `DrawBoard(P, parts)` | draws the built-in board; `parts`: `graphic`, `wheel`, `under`, `grip`, `rocket`, `deck = false` (no deck), `trucks = false` (no trucks or wheels) |

Set `image = true` on your type if it shows the deck image, so the player's image
is uploaded only while your type is picked.

# Board effects

Underglow, trails and grind sparks are effects: one file each in
`lua/skategm_fx/`, registered with `BOARD.RegisterEffect`. They work like board
types: typed fields become convars, are sent to everyone with the board look,
are cleaned on the server and get menu controls (in the Effects section of Your
board). The fields here also accept the `color` kind (an "r g b" string, shown as a
colour picker). `BOARD.COLOUR_MODES` is the shared "My player colour / Rainbow /
This colour" choice.

```lua
-- lua/skategm_fx/halo.lua
local HALO = BOARD.RegisterEffect({
	id = "halo", title = "Halo", order = 10,   -- id: letters and digits only
	fields = {
		{ key = "on", kind = "bool", convar = "halo_on", default = false, label = "Halo over my head" },
		{ key = "mode", kind = "choice", convar = "halo_mode", choices = BOARD.COLOUR_MODES, default = 2, label = "Halo colour" },
		{ key = "color", kind = "color", convar = "halo_color", default = "255 230 120", label = "Halo: custom colour", showWhen = { "mode", 3 } },
	},
})
if not CLIENT then return end
function HALO.enabled(o) return o.on end
function HALO.draw(ctx)
	local col = ctx.C.FxColour(ctx.opts.mode, ctx.opts.color, ctx.ply, ctx.now)
	render.SetColorMaterial()
	render.DrawSphere(ctx.P.HEAD + Vector(0, 0, 10), 4, 10, 10, col)
end
```

`draw(ctx)` runs whenever the skater is drawn (possibly more than once a frame:
mirrors, reflections). `ctx.newFrame` is true once per frame; emit particles or
record history only then. `ctx`: `ply`, `P` (bone positions), `B` (the board:
`centre`, `fwd`, `right`, `up`, `half`, wheel and truck points), `opts`,
`state` (engine state, e.g. "GrindFiftyFifty"), `now`, `dt`, `speed` (units/s),
`jumped` (teleported this frame), `data` (a table kept per skater for your
effect), `C` (the board client: `FxColour`). `off(data)` runs when the effect is
switched off or the skater goes away.
