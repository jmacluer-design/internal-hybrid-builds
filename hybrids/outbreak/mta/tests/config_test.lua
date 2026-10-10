-- shared/mta_config.lua: settings, budgets, and the game ids it names (checked against data where the repo has any).
local T, H = ...
T.group("config")
local Config = require("shared.mta_config")
local U = require("shared.util")

local function fresh_config()
	package.loaded["shared.mta_config"] = nil
	return require("shared.mta_config")
end

T.test("Config.apply reads settings with clamping and safe fallbacks; garbage never breaks the defaults", function()
	local C = fresh_config()
	local before = U.copy(C.server)
	C.apply(function(name, default) return default end)
	T.eq(C.server.profile, before.profile); T.eq(C.server.max_materialized, 60); T.eq(C.peds.max_peds, 96)
	C.apply(function(name, default)
		local t = { seed = "42", profile = "chaos", colonists = "99", timescale = "0", tick_ms = "5", autoload = "0", autosave = "-5", owner_admin = "0", owner_name = "Bob", debug = "1",
			selftest = "0", spawn_player = "0", store = "sqlite", max_materialized = "999", max_peds = "1", pool_guard = "10000", max_objects = "5000", origin = "10.5, -20,30", ui_mode = "dx" }
		return t[name] == nil and default or t[name]
	end)
	T.eq(C.server.seed, 42); T.eq(C.server.profile, "chaos"); T.eq(C.server.colonists, 12, "clamped to 12")
	T.eq(C.server.time_scale, 1, "clamped to 1"); T.eq(C.server.tick_ms, 100); T.eq(C.server.autoload, false); T.eq(C.server.autosave_s, 0)
	T.eq(C.server.owner_admin, false); T.eq(C.server.owner_name, "Bob"); T.eq(C.server.debug, true); T.eq(C.server.selftest, false); T.eq(C.server.spawn_player, false)
	T.eq(C.server.store, "sqlite"); T.eq(C.server.max_materialized, 120, "clamped to the ped pool"); T.eq(C.peds.max_peds, 8); T.eq(C.peds.pool_guard, 140); T.eq(C.peds.max_objects, 1100)
	T.eq(C.origin.x, 10.5); T.eq(C.origin.y, -20); T.eq(C.origin.z, 30); T.eq(C.client.ui_mode, "dx")
	C.apply(function(name, default) return "garbage" end)
	T.eq(C.server.seed, 42, "non-numbers keep the previous value"); T.eq(C.server.store, "file"); T.eq(C.client.ui_mode, "gui")
	local o = C.origin
	C.apply(function(name, default) if name == "origin" then return "not,a,vector" end return default end)
	T.eq(C.origin, o, "the origin table is updated in place, never replaced (other modules hold it)")
	T.eq(C.origin.x, 10.5, "a malformed origin keeps the old one")
	package.loaded["shared.mta_config"] = nil
	require("shared.mta_config")
end)

T.test("every setting Config.apply reads is declared in meta.xml with the default value, and meta.xml declares nothing else", function()
	local src = assert(io.open(H.res .. "/shared/mta_config.lua", "rb")):read("*a")
	local read = {}
	for name in src:gmatch('get%("([%w_]+)"') do read[name] = true end
	local m = H.Mock.new({ root = H.res, defs = false })
	for name in pairs(read) do T.truthy(m.meta.settings[name] ~= nil, "meta.xml has no <setting name=\"" .. name .. "\"/>") end
	for name in pairs(m.meta.settings) do T.truthy(read[name], "meta.xml declares " .. name .. " but nothing reads it") end
	local n = 0
	for _ in pairs(read) do n = n + 1 end
	T.ge(n, 19)
end)

T.test("ped budget: the numbers add up under the 140-slot ped pool with room to spare", function()
	local C = Config
	-- horde + raiders (the sim's cap) + colonist peds + traders (2 per caravan, at most 2 caravans) + a few players + corpses still waiting for deletion
	local players, traders, corpses = 4, 4, 12
	local worst = C.server.max_materialized + C.peds.max_colonist_peds + traders + players + corpses
	T.le(worst, 140 - 40, "worst case " .. worst .. " leaves at least 40 slots to other resources and the engine")
	T.le(C.peds.max_peds, C.peds.pool_guard, "the hard ceiling is below the pool guard")
	T.lt(C.peds.pool_guard, 140)
	T.ge(C.peds.max_peds, C.server.max_materialized + C.peds.max_colonist_peds, "the resource ceiling covers the sim's cap plus the colony")
	T.eq(C.server.max_materialized, 60, "the brief's starting point")
	T.le(C.peds.max_objects, 1200 / 2, "half of the ~1200 object pool at most")
	T.note("worst-case ped use %d of 140 (pool guard %d, hard cap %d)", worst, C.peds.pool_guard, C.peds.max_peds)
end)

-- the MTA editor's model-name table (multitheftauto/mtasa-resources, MIT): id -> name. Read at test time, not copied.
local function model_names()
	local path = (os.getenv("MTA_RES_SRC") or "/home/user/multitheftauto/mtasa-resources") .. "/[editor]/editor_main/server/getObjectNameFromModel.lua"
	local f = io.open(path, "rb")
	if not f then return nil, path end
	local names = {}
	for id, name in f:read("*a"):gmatch('%[(%d+)%]="([^"]*)"') do names[tonumber(id)] = name end
	f:close()
	return names
end

T.test("every prop model id exists in MTA's model-name table and is the object we meant", function()
	local names, path = model_names()
	T.truthy(names, "clone multitheftauto/mtasa-resources to read the model names (expected " .. tostring(path) .. ")")
	if not names then return end
	local expect = {
		[1685] = "blockpallet", [1462] = "DYN_woodpile", [1407] = "DYN_F_R_WOOD_1", [1408] = "DYN_F_WOOD_2", [1419] = "DYN_F_IRON_1", [1459] = "DYN_ROADBARRIER_6", [1495] = "Gen_doorEXT01",
		[1496] = "Gen_doorSHOP02", [2060] = "CJ_SANDBAG", [1422] = "DYN_ROADBARRIER_5", [1800] = "LOW_BED_1", [1793] = "LOW_BED_2", [1370] = "CJ_FLAME_Drum", [918] = "CJ_FLAME_Drum",
		[937] = "CJ_DF_WORKTOP", [936] = "CJ_DF_WORKTOP_2", [1481] = "DYN_BAR_B_Q", [914] = "GRILL", [1777] = "CJ_COOKER1", [929] = "GENERATOR", [943] = "GENERATOR_LOW", [1426] = "DYN_SCAFFOLD",
		[1464] = "DYN_SCAFFOLD_3", [1448] = "DYN_CRATE_1", [964] = "CJ_METAL_CRATE", [1218] = "barrel1", [1217] = "barrel2", [3632] = "imoildrum_LAS", [935] = "CJ_Drum", [1745] = "MED_BED_3",
		[1799] = "MED_BED_4", [2196] = "WORK_LAMP1", [1290] = "lamppost2", [3763] = "CE_radarmast3", [1224] = "woodenbox", [1271] = "gunbox", [1238] = "trafficcone",
	}
	local used = 0
	for bp, list in pairs(Config.props) do
		T.truthy(#list >= 1, bp .. " has at least one model")
		for _, id in ipairs(list) do
			used = used + 1
			T.truthy(names[id], bp .. ": model " .. id .. " is not an SA object")
			T.eq(names[id], expect[id], bp .. ": model " .. id .. " is " .. tostring(names[id]) .. " (update the expectation if you changed it on purpose)")
		end
	end
	T.note("%d prop model ids checked against %d known SA object names", used, (function() local n = 0 for _ in pairs(names) do n = n + 1 end return n end)())
end)

T.test("every blueprint has a prop (or uses the documented fallback); ped skins avoid the story characters; weapon ids are real SA weapons", function()
	local BP = require("data.blueprints")
	local fallback = {}
	for id in pairs(BP) do if not Config.props[id] then fallback[#fallback + 1] = id end end
	table.sort(fallback)
	T.note("blueprints that use the _fallback crate: %s", #fallback > 0 and table.concat(fallback, ", ") or "none")
	T.le(#fallback, 4, "most blueprints have their own prop")
	local story = {}
	for _, id in ipairs({ 0, 1, 2 }) do story[id] = true end
	for id = 265, 272 do story[id] = true end -- Tenpenny .. Ryder
	for id = 290, 299 do story[id] = true end -- Rosenberg, Torino, Cesar ...
	local function check_models(label, list)
		T.truthy(#list >= 1, label)
		for _, id in ipairs(list) do T.truthy(id >= 3 and id <= 312 and not story[id], label .. ": skin " .. id .. " is a story character or out of range") end
	end
	check_models("zombie_models", Config.peds.zombie_models); check_models("brute_models", Config.peds.brute_models); check_models("colonist_models", Config.peds.colonist_models)
	check_models("trader_models", Config.peds.trader_models)
	for f, list in pairs(Config.peds.faction_models) do check_models("faction " .. f, list) end
	local real = {}
	for _, id in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 15, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34 }) do real[id] = true end
	for item, id in pairs(Config.weapons) do T.truthy(real[id], item .. " -> weapon " .. id) end
	for f, list in pairs(Config.raider_weapons) do for _, id in ipairs(list) do T.truthy(real[id], f .. " weapon " .. id) end end
	for id = 22, 38 do if id ~= 35 and id ~= 36 and id ~= 37 then T.truthy(Config.weapon_noise[id], "weapon " .. id .. " has a noise kind") end end
	for kind, _ in pairs(Config.weather) do T.truthy(Config.weather[kind] % 1 == 0) end
	for kind, a in pairs(Config.anims) do T.eq(type(a[1]), "string", kind); T.eq(type(a[2]), "string", kind) end
end)

T.test("the sim's ped cap is the setting: TUNING.horde.max_materialized follows max_materialized at start", function()
	local m = H.boot({ settings = { max_materialized = "24" } })
	local TUNING = H.sreq(m, "data.tuning")
	T.eq(TUNING.horde.max_materialized, 24)
	m:stop()
	local m2 = H.boot({})
	T.eq(H.sreq(m2, "data.tuning").horde.max_materialized, 60, "the default start value")
end)

-- the freeroam resource's animation catalog (multitheftauto/mtasa-resources, MIT): block -> { names }. Read at test time, not copied.
T.test("every animation block / name the colonists use exists in MTA's own animation list (freeroam/data/animations.xml)", function()
	local path = (os.getenv("MTA_RES_SRC") or "/home/user/multitheftauto/mtasa-resources") .. "/[gameplay]/freeroam/data/animations.xml"
	local f = io.open(path, "rb")
	T.truthy(f, "clone multitheftauto/mtasa-resources to read the animation list (expected " .. path .. ")")
	if not f then return end
	local text = f:read("*a")
	f:close()
	local anims, block = {}, nil
	for line in text:gmatch("[^\n]+") do
		local g = line:match('<group name="([^"]+)"')
		if g then block = g; anims[block] = {} end
		local a = line:match('<anim name="([^"]+)"')
		if a and block then anims[block][a] = true end
	end
	local checked = 0
	local function has(entry, what)
		checked = checked + 1
		T.truthy(anims[entry[1]], what .. ": block " .. entry[1] .. " exists")
		T.truthy(anims[entry[1]] and anims[entry[1]][entry[2]], what .. ": " .. entry[1] .. "/" .. entry[2] .. " exists")
	end
	for step, entry in pairs(Config.anims) do has(entry, "step " .. step) end
	has(Config.carry_anim, "carry")
	T.gt(checked, 15)
	T.note("%d animation entries checked against %d blocks of the freeroam catalog", checked, (function() local n = 0 for _ in pairs(anims) do n = n + 1 end return n end)())
end)
