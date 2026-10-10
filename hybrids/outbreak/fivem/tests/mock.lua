-- fivem/tests/mock.lua : a mock FiveM. It loads the REAL server and client Lua of the resource into two separate environments (like FiveM's one-Lua-state-per-
-- script-side), each with fake globals and natives, a cooperative scheduler (CreateThread / Wait driven by a fake game timer), an event bus with msgpack-safety
-- checking on every network payload, KVP, convars, an entity world (peds with positions that walk towards their task destination, objects, cams, blips,
-- relationship groups, a ped pool), and NUI message / callback capture. It runs identically under lua5.4 and luajit.
--
-- WHAT THIS CAN NOT PROVE (also stated in fivem/README.md): that the real natives behave as the mock does (pathfinding, collision, streaming, animation names,
-- model names, ped pool size, ragdoll, relationship AI, NUI focus semantics, camera feel). The mock proves sequencing, bookkeeping, caps, cleanup and protocol.
local real_load = load
local real_print = print
local U = nil -- shared.util, loaded lazily from the resource (set by Mock.new)

local Mock = {}
Mock.__index = Mock

local unpack = table.unpack or unpack
local here = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or "."

-- stable name -> number map (the real GetHashKey is Jenkins one-at-a-time; the mock only needs a deterministic, collision-free-enough map and
-- must parse under LuaJIT, which has no bitwise operators)
local function joaat(s)
	s = s:lower()
	local h = 5381
	for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967291 end
	return h
end
Mock.joaat = joaat

local function terrain(x, y) return 30.0 + 2.0 * math.sin(x * 0.02) + 2.0 * math.cos(y * 0.02) end
Mock.terrain = terrain

local function copy_payload(v, path)
	-- what msgpack would do to a payload: a deep copy (no shared references); the safety check runs first
	if type(v) ~= "table" then return v end
	local out = {}
	for k, x in pairs(v) do out[k] = copy_payload(x) end
	return out
end

-- ------------------------------------------------------------------------------------------------------------------------ construction
function Mock.new(opts)
	opts = opts or {}
	local m = setmetatable({}, Mock)
	m.root = opts.root or error("Mock.new: root (the resource folder) is required")
	m.t = 0                       -- fake GetGameTimer() in ms
	m.frame_ms = opts.frame_ms or 33
	m.handle = 1000
	m.ents = {}
	m.rel_groups = {}
	m.rels = {}
	m.kvp = opts.kvp or {}
	m.convars = opts.convars or {}
	m.log = {}
	m.calls = {}                  -- native name -> count
	m.net = { to_server = {}, to_client = {}, bad_payloads = {}, delivered = 0 }
	m.nui_msgs = {}
	m.sides = {}
	m.ambient_peds = opts.ambient_peds or 0   -- fake non-resource peds filling the game's ped pool
	m.valid_models = {}                        -- name -> false makes IsModelInCdimage fail
	m.invalid_models = opts.invalid_models or {}
	m.model_load_ms = opts.model_load_ms or 60
	m.models = {}                              -- hash -> { name, requested_at }
	m.env = { blackout = false, clock = nil, clock_paused = false, weather = nil, ms_per_min = 2000, scenarios = {}, ped_budget = 3, veh_budget = 3, wanted = 5,
		dispatch = {}, random_cops = true, nui_focus = false, density_calls = 0 }
	m.cams = { active = nil, rendering = false, count = 0 }
	m.player = { ped = nil, id = 0, server_id = opts.server_id or 7, shooting = false, group = nil, sprint = false, in_vehicle = false, heading = 0.0 }
	m.script = { nui_cb = {}, commands = {}, keymaps = {} }
	m.owner_source = m.player.server_id
	m.created = { peds = 0, objects = 0, blips = 0, cams = 0 }
	m.markers = 0
	m.lights = 0
	m.shape_tests = {}
	m.explosion = nil
	m.player_speed = 0.0
	m.focus = nil
	m.cleanups = 0
	m.real_load = real_load
	m.pending_net = {}
	-- the player's ped
	local px, py = 2.0, 0.0
	m.player.ped = m:new_entity("ped", { x = px, y = py, z = terrain(px, py), model = "mp_m_freemode_01", mine = false, player = true, health = 200 })
	return m
end

function Mock:new_entity(kind, props)
	self.handle = self.handle + 1
	local e = { handle = self.handle, kind = kind, health = 200, alpha = 255, collision = true, exists = true, created_t = self.t, flags = {} }
	for k, v in pairs(props) do e[k] = v end
	self.ents[e.handle] = e
	return e
end

function Mock:count(kind, only_mine)
	local n = 0
	for _, e in pairs(self.ents) do
		if e.exists and e.kind == kind and (not only_mine or e.mine) then n = n + 1 end
	end
	return n
end

function Mock:entities(kind, only_mine)
	local out = {}
	for _, e in pairs(self.ents) do
		if e.exists and e.kind == kind and (not only_mine or e.mine) then out[#out + 1] = e end
	end
	table.sort(out, function(a, b) return a.handle < b.handle end)
	return out
end

-- ------------------------------------------------------------------------------------------------------------------------ sides + scheduler
local STD = { "assert", "collectgarbage", "error", "getmetatable", "ipairs", "next", "pairs", "pcall", "rawequal", "rawget", "rawset", "select", "setmetatable",
	"tonumber", "tostring", "type", "unpack", "xpcall", "string", "table", "math", "os", "coroutine", "utf8", "bit", "bit32", "jit", "_VERSION", "setfenv", "getfenv" }

function Mock:make_side(name)
	local side = { name = name, threads = {}, handlers = {}, net_events = {}, queue = {}, m = self }
	local env = {}
	for _, k in ipairs(STD) do if _G[k] ~= nil then env[k] = _G[k] end end
	env.print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
		self.log[#self.log + 1] = "[" .. name .. "] " .. table.concat(parts, " ")
		if self.echo then real_print("[" .. name .. "] " .. table.concat(parts, " ")) end
	end
	env.load = function(chunk, chunkname, mode, e) return real_load(chunk, chunkname, mode or "t", e or env) end
	env._G = env
	side.env = env
	self.sides[name] = side
	self:install_runtime(side)
	return side
end

-- run `fn` in a new thread of `side`; runs until its first Wait
function Mock:spawn(side, fn, ...)
	local co = coroutine.create(fn)
	local th = { co = co, wake = self.t, side = side, args = { ... }, first = true }
	side.threads[#side.threads + 1] = th
	self:resume(th)
	return th
end

function Mock:resume(th)
	if coroutine.status(th.co) == "dead" then return end
	local ok, res
	if th.first then
		th.first = false
		ok, res = coroutine.resume(th.co, unpack(th.args))
	else
		ok, res = coroutine.resume(th.co)
	end
	if not ok then
		self.errors = self.errors or {}
		self.errors[#self.errors + 1] = string.format("[%s] thread error: %s", th.side.name, tostring(res))
		if self.echo then real_print(self.errors[#self.errors]) end
		th.dead = true
		return
	end
	if coroutine.status(th.co) == "dead" then th.dead = true; return end
	th.wake = self.t + math.max(0, tonumber(res) or 0)
end

-- advance the fake clock by `ms` in frames; each frame wakes due threads (creation order, server first), delivers net events, moves peds
function Mock:step(ms)
	local left = ms
	while left > 0 do
		local dt = math.min(self.frame_ms, left)
		left = left - dt
		self.t = self.t + dt
		self:deliver_net()
		for _, name in ipairs({ "server", "client" }) do
			local side = self.sides[name]
			if side then
				local i = 1
				local threads = side.threads
				while i <= #threads do
					local th = threads[i]
					if th.dead then table.remove(threads, i)
					else
						if th.wake <= self.t then self:resume(th) end
						i = i + 1
					end
				end
			end
		end
		self:physics(dt)
	end
end

function Mock:run(seconds) self:step(math.floor(seconds * 1000)) end

-- ------------------------------------------------------------------------------------------------------------------------ events + network
local function ev_key(name) return name end

function Mock:fire_local(side, name, ...)
	local list = side.handlers[ev_key(name)]
	if not list then return 0 end
	local n = 0
	local snapshot = {}
	for i = 1, #list do snapshot[i] = list[i] end
	for _, fn in ipairs(snapshot) do
		self:spawn(side, fn, ...)
		n = n + 1
	end
	return n
end

function Mock:check_payload(topic, dir, ...)
	U = U or self:util()
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		local ok, why = U.msgpack_safe(v)
		if not ok then
			self.net.bad_payloads[#self.net.bad_payloads + 1] = string.format("%s %s arg %d: %s", dir, topic, i, why)
		end
	end
end

function Mock:util()
	if self._util then return self._util end
	local f = assert(real_load(assert(io.open(self.root .. "/shared/util.lua", "rb")):read("*a"), "@shared/util.lua"))
	self._util = f()
	return self._util
end

function Mock:deliver_net()
	if #self.pending_net == 0 then return end
	local q = self.pending_net
	self.pending_net = {}
	for _, item in ipairs(q) do
		if item.due <= self.t then
			local side = self.sides[item.to]
			if side then
				self.net.delivered = self.net.delivered + 1
				local prev = side.env.source
				side.env.source = item.source
				self:fire_local(side, item.name, unpack(item.args, 1, item.n))
				side.env.source = prev
			end
		else
			self.pending_net[#self.pending_net + 1] = item
		end
	end
end

function Mock:send_net(to, name, source, ...)
	self:check_payload(name, to == "server" and "client->server" or "server->client", ...)
	local args = {}
	local n = select("#", ...)
	for i = 1, n do args[i] = copy_payload((select(i, ...))) end
	self.pending_net[#self.pending_net + 1] = { to = to, name = name, source = source, args = args, n = n, due = self.t + (self.net_latency or 20) }
	local bucket = (to == "server") and self.net.to_server or self.net.to_client
	bucket[name] = (bucket[name] or 0) + 1
	if self.capture then
		self.captured = self.captured or {}
		local list = self.captured[to .. ":" .. name]
		if not list then list = {}; self.captured[to .. ":" .. name] = list end
		list[#list + 1] = { t = self.t, args = args, n = n }
	end
end

-- captured payloads of one topic ("client:outbreak:events" / "server:outbreak:in" ...) when m.capture was set before the traffic happened
function Mock:sent(to, name) return (self.captured and self.captured[to .. ":" .. name]) or {} end

-- every OUT event the server ever sent to the client (flattened from the batches), optionally filtered by type
function Mock:out_events(ev_type)
	local out = {}
	for _, item in ipairs(self:sent("client", "outbreak:events")) do
		for _, e in ipairs(item.args[1].events) do if not ev_type or e.type == ev_type then out[#out + 1] = e end end
	end
	return out
end

-- every IN event the client ever sent to the server, optionally filtered by type
function Mock:in_events(ev_type)
	local out = {}
	for _, item in ipairs(self:sent("server", "outbreak:in")) do
		for _, e in ipairs(item.args[1]) do if not ev_type or e.type == ev_type then out[#out + 1] = e end end
	end
	return out
end

-- step until fn() is truthy (checked every frame) or `max_ms` of fake time has passed; returns whether it became true
function Mock:wait_until(fn, max_ms)
	local waited = 0
	while waited < (max_ms or 10000) do
		if fn() then return true end
		self:step(self.frame_ms)
		waited = waited + self.frame_ms
	end
	return fn() and true or false
end

-- ------------------------------------------------------------------------------------------------------------------------ runtime globals
function Mock:install_runtime(side)
	local env, m = side.env, self
	local function count(name) m.calls[name] = (m.calls[name] or 0) + 1 end
	env.Wait = function(ms)
		count("Wait")
		local _, ismain = coroutine.running()
		if ismain then error("Wait called outside a thread (mock)", 2) end
		return coroutine.yield(ms or 0)
	end
	env.CreateThread = function(fn) count("CreateThread"); m:spawn(side, fn) end
	env.SetTimeout = function(ms, fn) m:spawn(side, function() env.Wait(ms); fn() end) end
	env.AddEventHandler = function(name, fn)
		local l = side.handlers[name]
		if not l then l = {}; side.handlers[name] = l end
		l[#l + 1] = fn
		return { name = name, fn = fn }
	end
	env.RegisterNetEvent = function(name, cb)
		side.net_events[name] = true
		if cb then env.AddEventHandler(name, cb) end
	end
	env.TriggerEvent = function(name, ...) m:fire_local(side, name, ...) end
	if side.name == "client" then
		env.TriggerServerEvent = function(name, ...) count("TriggerServerEvent"); m:send_net("server", name, m.player.server_id, ...) end
	else
		env.TriggerClientEvent = function(name, target, ...)
			count("TriggerClientEvent")
			if tonumber(target) ~= m.player.server_id and tonumber(target) ~= -1 then m.net.dropped_unknown_target = (m.net.dropped_unknown_target or 0) + 1; return end
			m:send_net("client", name, nil, ...)
		end
	end
	env.GetCurrentResourceName = function() return "outbreak" end
	env.LoadResourceFile = function(res, path)
		count("LoadResourceFile")
		local f = io.open(m.root .. "/" .. path, "rb")
		if not f then return nil end
		local s = f:read("*a")
		f:close()
		return s
	end
	env.GetGameTimer = function() return m.t end
	env.GetConvar = function(name, default) local v = m.convars[name]; if v == nil then return default end return tostring(v) end
	env.RegisterCommand = function(name, fn, restricted)
		count("RegisterCommand")
		m.script.commands[side.name .. ":" .. name] = { fn = fn, restricted = restricted }
	end
	env.RegisterKeyMapping = function(cmd, desc, dev, key) m.script.keymaps[#m.script.keymaps + 1] = { cmd = cmd, desc = desc, device = dev, key = key } end
	env.GetResourceKvpString = function(k) return m.kvp[k] end
	env.SetResourceKvp = function(k, v)
		assert(type(v) == "string", "SetResourceKvp: value must be a string")
		m.kvp[k] = v
	end
	env.DeleteResourceKvp = function(k) m.kvp[k] = nil end
	env.IsPlayerAceAllowed = function(src, obj) return m.aces and m.aces[tostring(src) .. ":" .. obj] or false end
	env.json = { encode = function(v) return m:json().encode(v) end, decode = function(s) return m:json().decode(s) end }
	if side.name == "client" then m:install_client_natives(side) else m:install_server_natives(side) end
end

function Mock:json()
	if self._json then return self._json end
	local f = assert(real_load(assert(io.open(self.root .. "/shared/json.lua", "rb")):read("*a"), "@shared/json.lua"))
	self._json = f()
	return self._json
end

function Mock:install_server_natives(side)
	-- the server only needs the runtime globals above; any other PascalCase global (a client native used on the server, a typo) is a loud error
	setmetatable(side.env, { __index = function(_, k)
		if type(k) == "string" and k:match("^%u") then error("mock: native/global '" .. k .. "' is not available on the SERVER", 2) end
		return nil
	end })
end

-- ------------------------------------------------------------------------------------------------------------------------ loading the resource
function Mock:load_script(side, path)
	local src = assert(io.open(self.root .. "/" .. path, "rb"), "cannot open " .. path):read("*a")
	local fn, err = real_load(src, "@" .. path, "t", side.env)
	assert(fn, err)
	local ok, e2 = pcall(fn)
	if not ok then error(path .. ": " .. tostring(e2), 0) end
end

function Mock:boot_server()
	local side = self.sides.server or self:make_side("server")
	self:load_script(side, "shared/boot.lua")
	self:load_script(side, "server/main.lua")
	return side
end

function Mock:boot_client()
	local side = self.sides.client or self:make_side("client")
	self:load_script(side, "shared/boot.lua")
	self:load_script(side, "client/main.lua")
	return side
end

-- the server host object (server/main.lua exposes OutbreakHost)
function Mock:host() return self.sides.server.env.OutbreakHost() end

function Mock:fire_resource_stop()
	for _, name in ipairs({ "client", "server" }) do
		local side = self.sides[name]
		if side then self:fire_local(side, "onResourceStop", "outbreak") end
	end
	self:step(self.frame_ms * 4)
end

-- simulate a NUI callback from the page (fetch https://outbreak/<name>); returns the response table passed to cb
function Mock:nui(name, data)
	local cb = self.script.nui_cb[name]
	assert(cb, "no NUI callback registered: " .. tostring(name))
	local out
	local side = self.sides.client
	self:spawn(side, function() cb(data or {}, function(r) out = r end) end)
	return out
end

function Mock:command(side_name, name, args, source)
	local c = self.script.commands[side_name .. ":" .. name]
	assert(c, "no command " .. name)
	local side = self.sides[side_name]
	self:spawn(side, function() c.fn(source or 0, args or {}, name) end)
end

function Mock:nui_messages(action)
	local out = {}
	for _, msg in ipairs(self.nui_msgs) do if not action or msg.action == action then out[#out + 1] = msg end end
	return out
end

dofile(here .. "/mock_natives.lua")(Mock)

return setmetatable(Mock, { __call = function(_, ...) return Mock.new(...) end })
