---------------------------------------------------------------------------
-- The park editor, client side: this player's snapping settings (sent to the
-- server as userinfo, read in sv_park.lua for the physgun's snapping).
---------------------------------------------------------------------------
local P = SKATEGM_PARTS
local PARK = P.park or {}
P.park = PARK
CreateClientConVar("skategm_parts_snap", "1", true, true, "Park parts snap to the nearest part's matching edge", 0, 1)
CreateClientConVar("skategm_parts_grid", "0", true, true, "Park parts not snapped to another round to this grid (units, 0 = off)", 0, 256)
CreateClientConVar("skategm_parts_turn", "15", true, true, "Park parts not snapped to another turn in steps of this many degrees (0 = off)", 0, 90)
