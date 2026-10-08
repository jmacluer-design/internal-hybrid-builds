local function Parts()
	local list = file.Find("skategm_parts/parts/*.lua", "LUA") or {}
	table.sort(list)
	for i, f in ipairs(list) do list[i] = "skategm_parts/parts/" .. f end
	return list
end

if SERVER then AddCSLuaFile("skategm_parts/sh_parts.lua") end
include("skategm_parts/sh_parts.lua")
for _, f in ipairs(Parts()) do
	if SERVER then AddCSLuaFile(f) end
	include(f)
end
-- the park editor: snapping and saved parks on the server, its settings page on
-- clients; the controller editor (LB + B) in both halves
if SERVER then
	include("skategm_parts/sv_park.lua")
	include("skategm_parts/sv_editor.lua")
	AddCSLuaFile("skategm_parts/cl_park.lua")
	AddCSLuaFile("skategm_parts/cl_editor.lua")
	AddCSLuaFile("skategm_parts/cl_saves.lua")
else
	include("skategm_parts/cl_park.lua")
	include("skategm_parts/cl_editor.lua")
	include("skategm_parts/cl_saves.lua")
end
