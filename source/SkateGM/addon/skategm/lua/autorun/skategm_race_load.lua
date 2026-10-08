-- Race: a separate game mode on top of Skater mode.
-- Everything lives in lua/skategm_race/; delete that folder (and this file) and
-- the rest of the add-on works exactly as before.
if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_race/sh_race.lua")
	AddCSLuaFile("skategm_race/cl_race.lua")
	include("skategm_race/sh_race.lua")
	include("skategm_race/sv_race.lua")
else
	include("skategm_race/sh_race.lua")
	include("skategm_race/cl_race.lua")
end
