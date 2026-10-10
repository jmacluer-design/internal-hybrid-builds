-- preview/glue.lua : runs INSIDE the browser (wasmoon, Lua 5.4 compiled to WebAssembly). It loads the REAL resource Lua
-- (sim/, data/, shared/) through sim/bootstrap.lua exactly like the FiveM server does with LoadResourceFile, builds the same
-- shared/host.lua the server uses, and exposes a handful of P_* functions the page calls. No GTA is involved: this is a UI test
-- bench and screenshot source. JS globals provided by the page: read_file(path), js_send(topic, json), js_store_get/set/del, js_log.
local boot = load(read_file("sim/bootstrap.lua"), "@sim/bootstrap.lua")()
boot.install(read_file, nil, true)

local Host = require("shared.host")
local json = require("shared.json")
local cfg = require("shared.config")
local view = require("shared.view")
local P = require("shared.protocol")

cfg.server.time_scale = 120 -- the bench runs 4x faster than GTA's default so a colony does something while you watch
cfg.server.autosave_s = 0

HOST = Host.new({
	cfg = cfg,
	send = function(topic, payload) js_send(topic, json.encode(payload)) end,
	store = { get = js_store_get, set = js_store_set, del = js_store_del },
	log = function(level, text) js_log(level, text) end,
})

local function decode(text)
	if text == nil or text == "" then return {} end
	local v, err = json.decode(text)
	if err then js_log("error", "bad json from page: " .. tostring(err)); return {} end
	return v
end

function P_new(seed, profile, colonists)
	local ok, err = HOST:new_game(seed, profile, colonists)
	return json.encode({ ok, err })
end

function P_advance(ms) return HOST:advance(ms) end
function P_ui(name, text) return json.encode({ HOST:ui_action(name, decode(text)) }) end
function P_order(text) return HOST:on_order(decode(text)) end
function P_in(text) return HOST:on_client_events(decode(text)) end
function P_status() return json.encode(HOST:status()) end
function P_hash() return HOST.world:hash() end
function P_state() return json.encode(HOST:state_view()) end
function P_catalog() return json.encode(view.catalog()) end
function P_set_scale(n) cfg.server.time_scale = n end
function P_set_speed(n) HOST:ui_action("set_speed", { speed = n }) end
function P_resync() HOST:emit_resync(true) end

-- state hash of the same fixed runs tests/hash_check.lua performs (default AI policy, 1-minute steps), as the same text lines
function P_hash_runs(days)
	local runner = require("sim.runner")
	local save = require("sim.save")
	local U = require("sim.util")
	local runs = { { seed = 1, profile = "calm" }, { seed = 2, profile = "escalating" }, { seed = 3, profile = "chaos" }, { seed = 11, profile = "calm" } }
	local lines = {}
	for _, r in ipairs(runs) do
		local res = runner.run({ seed = r.seed, profile = r.profile, days = days, max_dt = 1 })
		local w = res.world
		local saved = save.save(w)
		local back = save.load(saved)
		lines[#lines + 1] = string.format("HASH %-10s seed=%-3d days=%d alive=%d day_reached=%d hash=%s save_bytes=%d reload_equal=%s",
			r.profile, r.seed, days, res.alive, res.day_reached, w:hash(), #saved, tostring(back:hash() == w:hash()))
		local keys = U.keys(res.stats)
		local parts = {}
		for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. U.fmt_num(res.stats[k]) end
		lines[#lines + 1] = "  stats " .. table.concat(parts, " ")
	end
	return table.concat(lines, "\n") .. "\n"
end

HOST:new_game(1, "escalating", 5)
return "glue ready"
