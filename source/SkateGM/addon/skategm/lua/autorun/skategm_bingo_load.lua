if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_bingo/sh_bingo.lua")
	AddCSLuaFile("skategm_bingo/cl_bingo.lua")
	include("skategm_bingo/sh_bingo.lua")
	include("skategm_bingo/sv_bingo.lua")
else
	include("skategm_bingo/sh_bingo.lua")
	include("skategm_bingo/cl_bingo.lua")
end
