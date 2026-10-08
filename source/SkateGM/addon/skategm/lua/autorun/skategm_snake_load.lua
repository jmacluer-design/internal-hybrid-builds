if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_snake/sh_snake.lua")
	AddCSLuaFile("skategm_snake/cl_snake.lua")
	include("skategm_snake/sh_snake.lua")
	include("skategm_snake/sv_snake.lua")
else
	include("skategm_snake/sh_snake.lua")
	include("skategm_snake/cl_snake.lua")
end
