if not file.Exists("skategm_modes/sh_modes.lua", "LUA") then return end
if SERVER then
	AddCSLuaFile("skategm_modes/sh_modes.lua")
	AddCSLuaFile("skategm_example_highspeed/sh_highspeed.lua")
	AddCSLuaFile("skategm_example_highspeed/cl_highspeed.lua")
end
if not SKATEGM_MODES or not SKATEGM_MODES.Register then include("skategm_modes/sh_modes.lua") end
include("skategm_example_highspeed/sh_highspeed.lua")
if SERVER then include("skategm_example_highspeed/sv_highspeed.lua") else include("skategm_example_highspeed/cl_highspeed.lua") end
