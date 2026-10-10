-- shared/protocol.lua : names of every network event / NUI message, and the validators the SERVER runs on everything a
-- client sends (a client is untrusted input even on a LAN). The sim itself never raises on bad data, but it would happily
-- accept a loudness of 1e9 or a 10 MB string, so the host sanitizes first and only forwards plain, bounded copies.
local U = require("shared.util")

local P = {}

-- ----- network events (msgpack) ------------------------------------------------------------------------------------
P.NET = {
	-- server -> client
	hello = "outbreak:hello",         -- { owner = true, origin = {..}, cfg = {..}, catalog_version }
	events = "outbreak:events",       -- { seq = n, events = { OUT event, ... } }   (API.md section 3)
	state = "outbreak:state",         -- UI view model (shared/view.lua)
	hud = "outbreak:hud",             -- survival HUD numbers
	clock = "outbreak:clock",         -- { t = sim minutes, hour, minute, day, scale }
	ui = "outbreak:ui",               -- { name = "...", data = ... } results of UI actions
	catalog = "outbreak:catalog",     -- static data for the UI (items, blueprints, traits ...)
	-- client -> server
	ready = "outbreak:ready",         -- client script finished loading
	inbound = "outbreak:in",          -- { IN event, ... }   (API.md section 4, validated by sanitize_in)
	order = "outbreak:order",         -- one player order (validated by sanitize_order)
	ui_action = "outbreak:ui_action", -- name, data (validated by the host)
}

-- ----- NUI messages (Lua -> page) and callbacks (page -> Lua) --------------------------------------------------------
P.NUI_OUT = { "catalog", "state", "hud", "compass", "event", "mode", "screen", "selection", "inventory", "toast", "place", "settings", "boot" }
P.NUI_IN = { "ready", "order", "ui", "mode", "mouse", "place", "focus", "close", "key" }

-- ----- sanitizing --------------------------------------------------------------------------------------------------
local MAP_LIMIT = 6000 -- sim units; the sim map is +-2400, allow some slack for the player roaming outside of it

local function str(v, maxlen)
	if type(v) ~= "string" then return nil end
	if #v > (maxlen or 48) then return nil end
	return v
end

local function pos(v)
	if type(v) ~= "table" then return nil end
	local x, y = U.num(v.x), U.num(v.y)
	if not x or not y then return nil end
	local z = U.num(v.z, 0)
	return { x = U.clamp(x, -MAP_LIMIT, MAP_LIMIT), y = U.clamp(y, -MAP_LIMIT, MAP_LIMIT), z = U.clamp(z, -2000, 2000) }
end
P.pos = pos

local DAMAGE_KINDS = { bite = true, scratch = true, cut = true, bullet = true, blunt = true, fall = true, fire = true, explosion = true }
local PARTS = { arm = true, leg = true, torso = true, head = true }
local ZKINDS = { walker = true, runner = true, brute = true, screamer = true }

local function id_of(v, prefixes)
	if type(v) ~= "string" or #v > 12 then return nil end
	local p, n = v:match("^(%a)(%d+)$")
	if not p or not prefixes:find(p, 1, true) or #n > 7 then return nil end
	return v
end

-- generic deep clean for order targets: plain, bounded, copied
local function clean(v, depth)
	depth = depth or 0
	local t = type(v)
	if t == "number" then return U.finite(v) and v or nil end
	if t == "boolean" then return v end
	if t == "string" then return #v <= 64 and v or nil end
	if t ~= "table" or depth >= 4 then return nil end
	local out, n = {}, 0
	local is_arr = #v > 0
	if is_arr then
		for i = 1, math.min(#v, 40) do
			local c = clean(v[i], depth + 1)
			if c ~= nil then n = n + 1; out[n] = c end
		end
	else
		for k, val in pairs(v) do
			if type(k) == "string" and #k <= 24 then
				n = n + 1
				if n > 40 then break end
				local c = clean(val, depth + 1)
				if c ~= nil then out[k] = c end
			end
		end
	end
	return out
end
P.clean = clean

local IN = {}

IN.noise = function(ev)
	local p = pos(ev.pos)
	local loud = U.num(ev.loudness)
	if not p or not loud or loud <= 0 then return nil, "bad noise" end
	return { type = "noise", pos = p, loudness = U.clamp(loud, 1, 400), kind = str(ev.kind, 24) or "noise" }
end

IN.ped_damage = function(ev)
	local id = id_of(ev.id, "c")
	local amount = U.num(ev.amount)
	if not id or not amount or amount <= 0 then return nil, "bad ped_damage" end
	local kind = DAMAGE_KINDS[ev.kind] and ev.kind or "blunt"
	local out = { type = "ped_damage", id = id, amount = U.clamp(amount, 0.1, 500), kind = kind }
	if PARTS[ev.part] then out.part = ev.part end
	return out
end

IN.ped_died = function(ev)
	local id = ev.id
	if id ~= "player" then id = id_of(id, "chr") end
	if not id then return nil, "bad ped_died" end
	local out = { type = "ped_died", id = id, cause = str(ev.cause, 32) }
	if ZKINDS[ev.zkind] then out.zkind = ev.zkind end
	return out
end

IN.player_state = function(ev)
	local p = pos(ev.pos)
	if not p then return nil, "bad player_state" end
	local out = { type = "player_state", pos = p }
	if type(ev.needs) == "table" then
		out.needs = {}
		for _, k in ipairs({ "hunger", "thirst", "fatigue", "hp" }) do
			local n = U.num(ev.needs[k])
			if n then out.needs[k] = U.clamp(n, 0, 1000) end
		end
		if type(ev.needs.infection) == "string" then out.needs.infection = str(ev.needs.infection, 16) end
	end
	return out
end

IN.container_opened = function(ev)
	local ref, ctype, p = str(ev.container, 64), str(ev.ctype, 24), pos(ev.pos)
	if not ref or ref == "" or not ctype or not p then return nil, "bad container_opened" end
	local out = { type = "container_opened", container = ref, ctype = ctype, pos = p }
	local danger = U.num(ev.danger)
	if danger then out.danger = U.clamp(math.floor(danger), 1, 5) end
	return out
end

IN.horde_report = function(ev)
	local id, p = id_of(ev.id, "h"), pos(ev.pos)
	if not id or not p then return nil, "bad horde_report" end
	return { type = "horde_report", id = id, pos = p }
end

IN.raid_report = function(ev)
	local id, p = id_of(ev.id, "r"), pos(ev.pos)
	if not id or not p then return nil, "bad raid_report" end
	return { type = "raid_report", id = id, pos = p }
end

IN.colonist_ref = function(ev)
	local id = id_of(ev.id, "c")
	local ref = ev.ref
	if not id then return nil, "bad colonist_ref" end
	if type(ref) ~= "number" and type(ref) ~= "string" then return nil, "bad colonist_ref" end
	if type(ref) == "string" and #ref > 64 then return nil, "bad colonist_ref" end
	if type(ref) == "number" and not U.finite(ref) then return nil, "bad colonist_ref" end
	return { type = "colonist_ref", id = id, ref = ref }
end

-- a client may only send these IN event types; `order`, `item_moved`, `time_set` go through their own paths
P.CLIENT_IN_TYPES = {}
for k in pairs(IN) do P.CLIENT_IN_TYPES[#P.CLIENT_IN_TYPES + 1] = k end -- sorted below
table.sort(P.CLIENT_IN_TYPES)

-- returns a clean IN event or nil, reason
function P.sanitize_in(ev)
	if type(ev) ~= "table" or type(ev.type) ~= "string" then return nil, "not an event" end
	local f = IN[ev.type]
	if not f then return nil, "event type not allowed from clients: " .. tostring(ev.type):sub(1, 24) end
	return f(ev)
end

-- ----- orders ------------------------------------------------------------------------------------------------------
P.ORDER_KINDS = {
	priority = true, draft = true, ["goto"] = true, equip = true, place_blueprint = true, cancel_blueprint = true, expedition = true,
	cancel_expedition = true, schedule = true, zone_create = true, zone_set = true, trade = true, gift = true, truce = true,
	amputation = true, toggle_building = true, set_profile = true,
}

function P.sanitize_order(ev)
	if type(ev) ~= "table" then return nil, "not an order" end
	local kind = ev.kind
	if type(kind) ~= "string" or not P.ORDER_KINDS[kind] then return nil, "unknown order kind" end
	local id = str(ev.id, 12)
	if not id or not (id == "colony" or id == "all" or id_of(id, "c")) then return nil, "bad order id" end
	local target = clean(ev.target)
	if target == nil and ev.target ~= nil then return nil, "bad order target" end
	local out = { type = "order", id = id, kind = kind, target = target }
	if kind == "goto" or kind == "place_blueprint" then
		local t = target
		local p = kind == "goto" and pos(t) or (type(t) == "table" and pos(t.pos))
		if not p then return nil, "bad order position" end
		if kind == "goto" then out.target = p else out.target = { bp = str(t.bp, 24), pos = p } end
		if kind == "place_blueprint" and not out.target.bp then return nil, "bad blueprint id" end
	end
	return out
end

-- ----- misc --------------------------------------------------------------------------------------------------------
function P.is_admin_command(name) return name:sub(1, 8) == "outbreak" end

return P
