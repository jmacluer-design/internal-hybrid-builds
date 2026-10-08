-- Own the Spot: a separate game mode on top of Skater mode.
-- Everything lives in lua/skategm_ots/; delete that folder (and this file) and
-- the rest of the add-on works exactly as before.
if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_ots/sh_ots.lua")
	AddCSLuaFile("skategm_ots/cl_ots.lua")
	include("skategm_ots/sh_ots.lua")
	include("skategm_ots/sv_ots.lua")
else
	include("skategm_ots/sh_ots.lua")
	include("skategm_ots/cl_ots.lua")
end
