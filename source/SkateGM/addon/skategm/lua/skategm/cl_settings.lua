local S = SkateGM
local L = S.L
local Say, TurnOff = L.Say, L.TurnOff

---------------------------------------------------------------------------
-- Advanced settings: garrysmod/data/skategm/config.txt
-- The finer settings also live in a commented text file (created on first
-- run). Edit it, then skategm_reload_config.
---------------------------------------------------------------------------
local CONFIG_FILE = "skategm/config.txt"
-- in file order: { key, convar, note } or { false, heading }
S.CONFIG = {
	{ false, "Where your game data is" },
	{ "data", "skategm_data", "the folder with your converted game data (the one holding private/)" },
	{ false, "How the map is turned into something good to skate on (Settings > Advanced has presets for these)" },
	{ "smooth", "skategm_smooth", "bumpy terrain: 0 = as built, 1 = light, 2 = strong" },
	{ "smooth_creases", "skategm_smooth_creases", "curves where ramps meet the ground, in quarter pipes and bowls: 1 = on, 0 = off" },
	{ "smooth_steps", "skategm_smooth_steps", "ramp over ledges and curbs up to this height, in units (0 = off, 8 = curbs, 12 at most)" },
	{ "collision_style", "skategm_collision_style", "0 = classic (default), 1 = experimental (bigger curves, more smoothing)" },
	{ "tiny_props_solid", "skategm_tiny_props_solid", "1 = tiny props (cans, bottles, rubble) are solid to the skater" },
	{ "solid_no_physics", "skategm_solid_no_physics", "1 = props with no physics model are solid (players walk through these)" },
	{ "world_scale", "skategm_world_scale", "how big the map is to the engine: 1 = true size, 0.75 = ramps a quarter smaller (0.5 to 1.5)" },
	{ false, "Engine" },
	{ "warm_engine", "skategm_warm_engine", "1 = load the game data in the background when you join (quicker start, uses memory)" },
	{ "block_air_dismount", "skategm_block_air_dismount", "1 = Y does nothing in the air (only if getting off mid-air keeps failing)" },
	{ "boost_amount", "skategm_boost_amount", "how much skategm_boost adds, in m/s" },
}
local CONFIG_HEADER = {
	"# Skater mode - advanced settings.",
	"# Edit a value, save, then type skategm_reload_config in the console (collision",
	"# settings take effect the next time Skater mode switches on).",
	"# Lines starting with # are notes. Delete this file to get the defaults back.",
	"# Debugging (console only, not saved): skategm_show_collision 1, skategm_bones 1.",
}

local function ConfigValue(convar)
	local cv = GetConVar and GetConVar(convar)
	return cv and cv:GetString() or nil
end

-- the file's text, from the current settings (with override = { key = value } on top)
function S.ConfigText(override)
	local lines = {}
	for _, l in ipairs(CONFIG_HEADER) do lines[#lines + 1] = l end
	for _, e in ipairs(S.CONFIG) do
		if e[1] == false then
			lines[#lines + 1] = ""
			lines[#lines + 1] = "# " .. e[2]
		else
			local v = (override and override[e[1]]) or ConfigValue(e[2]) or ""
			lines[#lines + 1] = string.format("%-20s = %-12s # %s", e[1], v, e[3])
		end
	end
	return table.concat(lines, "\n") .. "\n"
end

-- key = value pairs from the file's text (notes and blank lines skipped)
function S.ParseConfig(text)
	local out, unknown = {}, {}
	local known = {}
	for _, e in ipairs(S.CONFIG) do if e[1] then known[e[1]] = e[2] end end
	for line in string.gmatch((text or "") .. "\n", "([^\n]*)\n") do
		local body = line:gsub("#.*$", "")
		local key, value = body:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
		if key then
			if known[key] then out[key] = value else unknown[#unknown + 1] = key end
		end
	end
	return out, unknown
end

function S.WriteConfig(override)
	if not (file and file.Write) then return end
	if file.CreateDir then file.CreateDir("skategm") end
	file.Write(CONFIG_FILE, S.ConfigText(override))
end

-- apply the file (creating it from the current settings if it isn't there yet)
function S.LoadConfig(quiet)
	if not (file and file.Read) then return 0 end
	if not (file.Exists and file.Exists(CONFIG_FILE, "DATA")) then
		S.WriteConfig()
		return 0
	end
	local values, unknown = S.ParseConfig(file.Read(CONFIG_FILE, "DATA"))
	local changed = 0
	for _, e in ipairs(S.CONFIG) do
		local v = e[1] and values[e[1]]
		if v and v ~= "" and v ~= ConfigValue(e[2]) then
			RunConsoleCommand(e[2], v)
			changed = changed + 1
		end
	end
	if not quiet and #unknown > 0 then Say("config.txt: unknown setting(s) " .. table.concat(unknown, ", ") .. " - ignored", true) end
	return changed
end

-- one setting changed from the menu: the file follows, so they never disagree
function S.SetConfig(key, value)
	for _, e in ipairs(S.CONFIG) do
		if e[1] == key then
			RunConsoleCommand(e[2], tostring(value))
			S.WriteConfig({ [key] = tostring(value) })
			return true
		end
	end
	return false
end

concommand.Add("skategm_reload_config", function()
	local n = S.LoadConfig()
	Say(n > 0 and string.format("config.txt: %d setting(s) changed%s", n, S.phase == "on" and " - collision changes apply when you next switch Skater mode on" or "") or "config.txt: nothing changed")
end, nil, "Skater mode: apply garrysmod/data/skategm/config.txt")
concommand.Add("skategm_config", function()
	if not (file and file.Exists and file.Exists(CONFIG_FILE, "DATA")) then S.WriteConfig() end
	Say("advanced settings: garrysmod/data/" .. CONFIG_FILE .. " - edit it, then type skategm_reload_config")
end, nil, "Skater mode: where the advanced settings file is")

---------------------------------------------------------------------------
-- collision smoothing presets, and reloading the collision
---------------------------------------------------------------------------
-- the smoothing presets: { label, terrain, creases, max ledge }
local PRESETS = {
	{ "None (as the map is built)", 0, 0, 0 },
	{ "Light (default: curbs up to 8 units ramped)", 1, 1, 8 },
	{ "Strong (ledges up to 12 units ramped)", 2, 1, 12 },
}
S.PRESETS = PRESETS
function S.ApplyPreset(i)
	local p = PRESETS[i]
	if not p then return end
	RunConsoleCommand("skategm_smooth", p[2])
	RunConsoleCommand("skategm_smooth_creases", p[3])
	RunConsoleCommand("skategm_smooth_steps", p[4])
	S.WriteConfig({ smooth = tostring(p[2]), smooth_creases = tostring(p[3]), smooth_steps = tostring(p[4]) })
end

-- reload the collision now with the current settings (if skating)
function S.ApplyCollisionNow()
	if S.phase == "on" or S.phase == "loading" then
		TurnOff()
		timer.Simple(0.3, function() RunConsoleCommand("skategm_toggle") end)
		Say("reloading the collision with the new settings...")
	else
		Say("the new settings apply when you switch Skater mode on")
	end
end

-- (the settings themselves are on the controller: LB + A > Settings, in
-- skategm_ui/cl_settings.lua)
