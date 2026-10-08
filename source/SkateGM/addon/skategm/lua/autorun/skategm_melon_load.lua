-- Melon King: a separate game mode on top of Skater mode.
-- Everything lives in lua/skategm_melon/; delete that folder (and this file) and
-- the rest of the add-on works exactly as before.
if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_melon/sh_melon.lua")
	AddCSLuaFile("skategm_melon/cl_melon.lua")
	include("skategm_melon/sh_melon.lua")
	include("skategm_melon/sv_melon.lua")
else
	include("skategm_melon/sh_melon.lua")
	include("skategm_melon/cl_melon.lua")
end
