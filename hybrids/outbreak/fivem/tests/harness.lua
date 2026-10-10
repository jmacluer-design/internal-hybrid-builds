-- fivem/tests/harness.lua : path setup + small helpers shared by the test files (run through tests/run.lua).
local H = {}

local here = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or "."
H.tests = here
H.fivem = here .. "/.."
H.res = H.fivem .. "/outbreak"          -- the resource folder (what a FiveM server would see)
H.sim_root = H.fivem .. "/../"          -- hybrids/outbreak (the canonical sim + its tests)
H.tools = H.fivem .. "/tools"

-- the resource's own files, reachable with require("shared.x") / require("sim.x") / require("client.x") as in FiveM after shared/boot.lua
package.path = H.res .. "/?.lua;" .. here .. "/?.lua;" .. H.sim_root .. "tests/?.lua;" .. package.path

local Mock = require("mock")
H.Mock = Mock

-- a booted mock: server + client, advanced `warm_ms` so the owner handshake and the first events have been processed
function H.boot(opts)
	opts = opts or {}
	local m = Mock.new({ root = H.res, convars = opts.convars or { outbreak_debug = "true" }, kvp = opts.kvp, ambient_peds = opts.ambient_peds,
		invalid_models = opts.invalid_models, model_load_ms = opts.model_load_ms })
	m.capture = opts.capture ~= false
	if opts.setup then opts.setup(m) end
	m:boot_server()
	if opts.client ~= false then m:boot_client() end
	m:step(opts.warm_ms or 3000)
	return m
end

-- the world of the booted server
function H.world(m) return m:host().world end

function H.errors_text(m) return m.errors and table.concat(m.errors, "\n") or "" end

-- count distinct values of an array
function H.count_if(list, fn)
	local n = 0
	for _, v in ipairs(list) do if fn(v) then n = n + 1 end end
	return n
end

return H
