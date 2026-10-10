-- mta/tests/mock_mta.lua : a mock MTA:SA. It loads the REAL server and client Lua of the resource (mta/outbreak) into two separate sandboxes, like MTA's one Lua VM per script side, and
-- feeds them fake elements, timers, events with MTA's remote-trigger rules, a file API, SQLite, a CEF browser and a physics step.
--
-- FIDELITY RULES (so that the mock cannot flatter the code):
--  * each sandbox only has the functions that exist on that side in the REAL source (tools/mta_defs.lua reads mtasa-blue), so a client-only function called on the server is a nil call;
--  * the libraries are Lua 5.1's: table.unpack / table.pack / table.move, string.pack, math.type, bit, jit, io, package are absent, `load` only takes a reader function, `require`, `dofile`,
--    `loadfile`, `getfenv` are the disabled stubs of MTA's CLuaMain::InitSecurity; reading an undefined global is an error (MTA would call nil), writing a global is recorded;
--  * events: a remote trigger only reaches an event registered with addEvent(name, true); `client` is the real sender, `source` is whatever the sender passed (spoofable, see spoof_server_event);
--  * client scripts only see files that the client downloaded (meta.xml <file> without download="false", client / shared scripts);
--  * every MTA call that takes an element raises on a destroyed one, a server ped has no physics unless a syncer client drives it.
-- WHAT THIS CAN NOT PROVE (also stated in mta/README.md): that the real MTA behaves like the mock: ped streaming and syncer assignment, animation and model names, whether peds obey
-- control states the way the driver assumes, collision and ground sampling, CEF focus and input routing, camera feel, weather / time details, the real 5.1 interpreter's quirks.
local here = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or "."
local Mock = {}
Mock.__index = Mock

local real_load = loadstring or load
local real_print = print
local unpack = table.unpack or unpack

local function terrain(x, y) return 18.0 + 1.5 * math.sin(x * 0.03) + 1.5 * math.cos(y * 0.03) end
Mock.terrain = terrain

-- ------------------------------------------------------------------------------------------------------------------------ element objects
local EL = {}
EL.__index = EL
EL.__tostring = function(e) return string.format("element:%s#%d", e.type, e.id) end

local function is_el(v) return type(v) == "table" and getmetatable(v) == EL end

-- ------------------------------------------------------------------------------------------------------------------------ construction
function Mock.new(opts)
	opts = opts or {}
	local m = setmetatable({}, Mock)
	m.root_dir = opts.root or error("Mock.new: root (the resource folder) is required")
	m.t = 0
	m.frame_ms = opts.frame_ms or 33
	m.net_latency = opts.net_latency or 20
	m.next_id = 0
	m.els = {}
	m.log = {}
	m.chat = {}
	m.errors = {}
	m.warnings = {}
	m.sound = {}
	m.sides = {}
	m.pending = {}
	m.captured = {}                 -- "to:name" -> list of { t, args }
	m.capture = opts.capture ~= false
	m.net = { bad_payloads = {}, dropped = {}, delivered = 0 }
	m.calls = {}                    -- function name -> count (both sides)
	m.fs = opts.fs or { server = {}, client = {} }
	m.fail = {}                     -- failure injection: fileCreate / fileWrite / fileOpen / dbExec / createPed / createObject
	m.settings = {}
	m.acl = {}                      -- "playername:right" -> true
	m.world = { minutes = 12 * 60, minute_ms = 1000, weather = 0, weather_blend = nil, sets = 0 }
	m.ambient_peds = opts.ambient_peds or 0
	m.invalid_ped_models = opts.invalid_ped_models or {}
	m.invalid_object_models = opts.invalid_object_models or {}
	m.screen = { w = 1920, h = 1080 }
	m.cam = { x = 0, y = 0, z = 0, lx = 0, ly = 1, lz = 0, fov = 70, target = nil, matrix_set = false }
	m.cursor = { showing = false, x = 0.5, y = 0.5 }
	m.input = { mode = "allow_binds", all_controls = true, controls = {}, focused_browser = nil }
	m.binds = {}
	m.commands = { server = {}, client = {} }
	m.hud = {}
	m.dx = { lines = 0, rects = 0, images = 0, texts = 0 }
	m.browser_js = {}
	m.browser_msgs = {}
	m.player_move_state = "stand"
	m.player_control = {}
	m.created = { peds = 0, objects = 0 }
	m.global_writes = { server = {}, client = {} }
	m.stats = { remote_rejected = 0 }

	local defs = opts.defs
	if defs == nil then
		package.path = here .. "/../tools/?.lua;" .. package.path
		local D = require("mta_defs")
		local d, err = D.load(opts.mtasa_src)
		if not d then error("mock_mta: " .. tostring(err)) end
		defs = d
	end
	m.defs = defs or false

	m.root = m:new_element("root", {})
	m.resource = { name = "outbreak", __resource = true }
	m.resourceRoot = m:new_element("resource", { name = "outbreak" }, m.root)
	m.console = m:new_element("console", {}, m.root)
	m:parse_meta()
	for k, v in pairs(opts.settings or {}) do m.settings[k] = tostring(v) end
	m.players = {}
	m.player = m:add_player(opts.player_name or "Owner", opts.player_serial)
	for i = 1, m.ambient_peds do m:new_element("ped", { model = 7, x = 5000.0 + i, y = 5000.0, z = 10.0, mine = false, created_by = "server", weapons = {}, controls = {}, stats = {} }, m.root) end
	return m
end

function Mock:new_element(kind, props, parent)
	self.next_id = self.next_id + 1
	local e = setmetatable({ id = self.next_id, type = kind, data = {}, children = {}, destroyed = false, alpha = 255, collisions = true, health = 100, x = 0.0, y = 0.0, z = 0.0, rx = 0.0, ry = 0.0, rz = 0.0,
		created_t = self.t }, EL)
	for k, v in pairs(props or {}) do e[k] = v end
	e.parent = parent
	if parent then parent.children[#parent.children + 1] = e end
	self.els[e.id] = e
	return e
end

function Mock:destroy_element(e)
	if e.destroyed then return false end
	for i = #e.children, 1, -1 do self:destroy_element(e.children[i]) end
	e.destroyed = true
	if e.parent then
		for i, c in ipairs(e.parent.children) do if c == e then table.remove(e.parent.children, i); break end end
	end
	if e.type == "ped" or e.type == "player" then e.alive_flag = false end
	-- timers / handlers attached to a destroyed element go with it (MTA removes the handlers)
	for _, side in pairs(self.sides) do
		for _, list in pairs(side.handlers) do for _, h in ipairs(list) do if h.el == e then h.removed = true end end end
	end
	self:fire_server_local("onElementDestroy", e)
	return true
end

function Mock:add_player(name, serial)
	local p = self:new_element("player", { name = name, serial = serial or ("SERIAL" .. tostring(#(self.players or {}) + 1)), x = 2.0, y = 0.0, z = terrain(2.0, 0.0) + 1.0, health = 100, spawned = false,
		dead = false, weapons = {}, controls = {}, inbox = {}, local_to_client = (#(self.players or {}) == 0) }, self.root)
	self.players = self.players or {}
	self.players[#self.players + 1] = p
	return p
end

-- ------------------------------------------------------------------------------------------------------------------------ meta.xml
function Mock:parse_meta()
	local f = assert(io.open(self.root_dir .. "/meta.xml", "rb"))
	local text = f:read("*a")
	f:close()
	self.meta = { scripts = {}, files = {}, settings = {} }
	for tag in text:gmatch("<script%s+([^>]-)/>") do
		local src, kind = tag:match('src="([^"]+)"'), tag:match('type="([^"]+)"') or "server"
		self.meta.scripts[#self.meta.scripts + 1] = { src = src, type = kind }
	end
	for tag in text:gmatch("<file%s+([^>]-)/>") do
		local src = tag:match('src="([^"]+)"')
		self.meta.files[src] = { download = tag:match('download="false"') == nil }
	end
	for k, v in text:gmatch('<setting%s+name="([^"]+)"%s+value="([^"]*)"') do self.settings[k] = v; self.meta.settings[k] = v end
	-- the files a client can open: downloadable <file>s and the client / shared scripts
	self.client_files = {}
	for src, info in pairs(self.meta.files) do if info.download then self.client_files[src] = true end end
	for _, s in ipairs(self.meta.scripts) do if s.type == "client" or s.type == "shared" then self.client_files[s.src] = true end end
end

-- ------------------------------------------------------------------------------------------------------------------------ sandboxes
local function filtered(src, keep)
	local out = {}
	for _, k in ipairs(keep) do if src[k] ~= nil then out[k] = src[k] end end
	return out
end

function Mock:make_side(name)
	local m = self
	local side = { name = name, env = nil, handlers = {}, events = {}, timers = {}, next_timer = 0, loaded = false, started = false }
	local env = {}
	for _, k in ipairs({ "assert", "collectgarbage", "error", "getmetatable", "ipairs", "next", "pairs", "pcall", "rawequal", "rawget", "rawset", "select", "setmetatable", "tonumber", "tostring", "type",
		"xpcall", "_VERSION" }) do env[k] = _G[k] end
	env.unpack = unpack
	env.string = filtered(string, { "byte", "char", "dump", "find", "format", "gmatch", "gsub", "len", "lower", "match", "rep", "reverse", "sub", "upper" })
	env.table = filtered(table, { "concat", "insert", "maxn", "remove", "sort", "getn" })
	env.math = filtered(math, { "abs", "acos", "asin", "atan", "ceil", "cos", "cosh", "deg", "exp", "floor", "fmod", "frexp", "huge", "ldexp", "log", "log10", "max", "min", "modf", "pi", "pow", "rad",
		"random", "randomseed", "sin", "sinh", "sqrt", "tan", "tanh" })
	env.math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
	env.math.pow = math.pow or function(a, b) return a ^ b end
	env.math.log10 = math.log10 or function(x) return math.log(x, 10) end
	env.os = { time = os.time, clock = os.clock, date = os.date, difftime = os.difftime }
	env.coroutine = filtered(coroutine, { "create", "resume", "running", "status", "wrap", "yield" })
	env.debug = { traceback = debug.traceback }
	env._G = env
	local function disabled() return false end
	env.dofile, env.loadfile, env.require, env.loadlib, env.getfenv, env.newproxy = disabled, disabled, disabled, disabled, disabled, disabled
	env.loadstring = function(src, chunkname)
		if type(src) ~= "string" then error("bad argument #1 to 'loadstring' (string expected)", 2) end
		if src:sub(1, 4) == "\27Lua" then return nil, "attempt to load a precompiled chunk" end
		if setfenv then
			local fn, err = real_load(src, chunkname)
			if fn then setfenv(fn, env) end
			return fn, err
		end
		return load(src, chunkname, "t", env)
	end
	env.load = function(reader)
		if type(reader) ~= "function" then error("Lua 5.1's load takes a reader function, not a string (use loadstring)", 2) end
		local parts = {}
		while true do local piece = reader(); if piece == nil or piece == "" then break end parts[#parts + 1] = piece end
		return env.loadstring(table.concat(parts), "=(load)")
	end
	env.setfenv = function() error("mock: setfenv is not supported", 2) end
	env.print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
		m.log[#m.log + 1] = "[" .. name .. "] " .. table.concat(parts, " ")
	end
	side.env = env
	self.sides[name] = side
	self:install_natives(side)
	-- strict globals: reading an undefined one is an error (MTA would call nil), writing one is recorded
	setmetatable(env, {
		__index = function(_, k)
			-- MTA's event-context variables are nil outside a handler that sets them (`client` exists only in remote server events): reading them is not an error
			if k == "source" or k == "this" or k == "client" or k == "eventName" or k == "sourceResource" or k == "sourceResourceRoot" or k == "sourceTimer" then return nil end
			error(string.format("mock: global '%s' is not defined on the %s (MTA would give nil, then fail on the call)", tostring(k), name), 2)
		end,
		__newindex = function(t, k, v) m.global_writes[name][k] = true; rawset(t, k, v) end,
	})
	return side
end

-- load one script file into a side
function Mock:load_script(side, path)
	local f = io.open(self.root_dir .. "/" .. path, "rb")
	if not f then error("mock: cannot open script " .. path) end
	local src = f:read("*a")
	f:close()
	local fn, err = side.env.loadstring(src, "@" .. path)
	if not fn then error("mock: " .. tostring(err), 0) end
	local ok, e2 = pcall(fn)
	if not ok then error(path .. ": " .. tostring(e2), 0) end
end

function Mock:load_side(name)
	local side = self.sides[name] or self:make_side(name)
	for _, s in ipairs(self.meta.scripts) do
		if s.type == name or s.type == "shared" then self:load_script(side, s.src) end
	end
	side.loaded = true
	return side
end

-- ------------------------------------------------------------------------------------------------------------------------ resource life cycle
function Mock:start_server()
	local side = self.sides.server or self:load_side("server")
	side.started = true
	self:trigger(side, "onResourceStart", self.resourceRoot, self.resource)
end

function Mock:start_client()
	local side = self.sides.client or self:load_side("client")
	side.started = true
	self:trigger(side, "onClientResourceStart", self.resourceRoot, self.resource)
end

function Mock:boot(opts)
	opts = opts or {}
	self:load_side("server")
	self:load_side("client")
	self:start_server()
	if opts.client ~= false then self:start_client() end
	self:step(opts.warm_ms or 3000)
	return self
end

function Mock:stop(opts)
	for _, name in ipairs({ "client", "server" }) do
		local side = self.sides[name]
		if side and side.started then
			self:trigger(side, name == "client" and "onClientResourceStop" or "onResourceStop", self.resourceRoot, self.resource)
		end
	end
	self:step(self.frame_ms * 4)
	if opts and opts.engine then self:engine_cleanup() end
end

-- what MTA itself does when a resource stops: destroy every element the resource created, kill its timers
function Mock:engine_cleanup()
	local mine = {}
	for _, e in pairs(self.els) do if e.mine and not e.destroyed then mine[#mine + 1] = e end end
	for _, e in ipairs(mine) do self:destroy_element(e) end
	for _, side in pairs(self.sides) do for _, t in pairs(side.timers) do t.dead = true end end
end

-- elements the resource created and has not destroyed (the leak check after stop)
function Mock:live(kind)
	local out = {}
	for _, e in pairs(self.els) do
		if e.mine and not e.destroyed and (kind == nil or e.type == kind) then out[#out + 1] = e end
	end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end

function Mock:live_timers()
	local n = 0
	for _, side in pairs(self.sides) do for _, t in pairs(side.timers) do if not t.dead then n = n + 1 end end end
	return n
end

-- ------------------------------------------------------------------------------------------------------------------------ the clock
function Mock:step(ms)
	local left = ms
	while left > 0 do
		local dt = math.min(self.frame_ms, left)
		left = left - dt
		self.t = self.t + dt
		self:deliver_net()
		self:run_timers("server")
		self:run_timers("client")
		self:physics(dt)
		local client = self.sides.client
		if client and client.started then
			self:trigger(client, "onClientPreRender", self.root, dt)
			self:trigger(client, "onClientRender", self.root)
		end
		self.world.minutes = self.world.minutes + dt / math.max(1, self.world.minute_ms)
	end
end

function Mock:run(seconds) self:step(math.floor(seconds * 1000)) end

-- step until fn() is truthy (checked every frame) or max_ms passed; returns whether it became true
function Mock:wait_until(fn, max_ms)
	local waited = 0
	while waited < (max_ms or 10000) do
		if fn() then return true end
		self:step(self.frame_ms)
		waited = waited + self.frame_ms
	end
	return fn() and true or false
end

function Mock:run_timers(name)
	local side = self.sides[name]
	if not side then return end
	local due = {}
	for id, t in pairs(side.timers) do if not t.dead and t.next_t <= self.t then due[#due + 1] = t end end
	table.sort(due, function(a, b) return a.id < b.id end)
	for _, t in ipairs(due) do
		if not t.dead then
			local ok, err = pcall(t.fn, unpack(t.args, 1, t.n))
			if not ok then self.errors[#self.errors + 1] = string.format("[%s] timer error: %s", name, tostring(err)) end
			if t.times > 0 then t.times = t.times - 1; if t.times == 0 then t.dead = true end end
			if not t.dead then t.next_t = t.next_t + t.interval; if t.next_t <= self.t then t.next_t = self.t + t.interval end end
		end
	end
end

-- ------------------------------------------------------------------------------------------------------------------------ events
local function ancestors(e)
	local out, cur = {}, e
	while cur do out[#out + 1] = cur; cur = cur.parent end
	return out
end

-- fire `name` on `side` for element `source`; ctx = { client = player } for remote server events. Returns true unless an handler cancelled it.
function Mock:trigger(side, name, source, ...)
	local list = side.handlers[name]
	local cancelled = false
	if list then
		local chain = ancestors(source)
		local snapshot = {}
		for _, h in ipairs(list) do snapshot[#snapshot + 1] = h end
		local env = side.env
		local args = { ... }
		local n = select("#", ...)
		for level, el in ipairs(chain) do
			for _, h in ipairs(snapshot) do
				if not h.removed and h.el == el and (level == 1 or h.propagate) then
					local prev_source, prev_this, prev_client, prev_name = rawget(env, "source"), rawget(env, "this"), rawget(env, "client"), rawget(env, "eventName")
					rawset(env, "source", source); rawset(env, "this", el); rawset(env, "eventName", name); rawset(env, "client", side.client_ctx)
					local prev_cancel = side.cancel_flag
					side.cancel_flag = false
					local ok, err = pcall(h.fn, unpack(args, 1, n))
					if not ok then self.errors[#self.errors + 1] = string.format("[%s] handler of %s failed: %s", side.name, name, tostring(err)) end
					if side.cancel_flag then cancelled = true end
					side.cancel_flag = prev_cancel
					rawset(env, "source", prev_source); rawset(env, "this", prev_this); rawset(env, "eventName", prev_name); rawset(env, "client", prev_client)
				end
			end
		end
	end
	return not cancelled
end

function Mock:fire_server_local(name, source, ...)
	local side = self.sides.server
	if side and side.started then return self:trigger(side, name, source, ...) end
end

-- MTA's argument rules for remote events: nil / boolean / number / string / element / plain tables (string or number keys); no functions, no cycles
function Mock:check_payload(topic, dir, ...)
	local U = self:util()
	local function walk(v, path, seen, depth)
		local t = type(v)
		if t == "nil" or t == "boolean" or t == "string" then return true end
		if t == "number" then if v ~= v or v == math.huge or v == -math.huge then return false, path .. ": non-finite number" end return true end
		if is_el(v) then if v.destroyed then return false, path .. ": destroyed element" end return true end
		if t ~= "table" then return false, path .. ": " .. t .. " cannot be sent" end
		if getmetatable(v) ~= nil then return false, path .. ": table with a metatable" end
		if depth > 30 then return false, path .. ": too deep" end
		if seen[v] then return false, path .. ": cycle" end
		seen[v] = true
		for k, x in pairs(v) do
			local kt = type(k)
			if kt ~= "string" and kt ~= "number" then return false, path .. ": bad key type " .. kt end
			local ok, why = walk(x, path .. "." .. tostring(k), seen, depth + 1)
			if not ok then return false, why end
		end
		seen[v] = nil
		return true
	end
	local all_ok = true
	for i = 1, select("#", ...) do
		local ok, why = walk((select(i, ...)), "$" .. i, {}, 0)
		if not ok then self.net.bad_payloads[#self.net.bad_payloads + 1] = string.format("%s %s: %s", dir, topic, why); all_ok = false end
		-- OUR stricter rule: apart from elements, payloads are msgpack-safe plain data (no sparse arrays, no mixed tables, bounded size)
		if ok and not self.allow_loose_payload then
			local v = select(i, ...)
			if type(v) == "table" and not is_el(v) and not self:contains_element(v) then
				local ok2, why2 = U.msgpack_safe(v)
				if not ok2 then self.net.bad_payloads[#self.net.bad_payloads + 1] = string.format("%s %s arg %d: %s", dir, topic, i, why2); all_ok = false end
			end
		end
	end
	return all_ok
end

function Mock:contains_element(v, depth)
	depth = depth or 0
	if depth > 6 then return false end
	for _, x in pairs(v) do
		if is_el(x) then return true end
		if type(x) == "table" and not is_el(x) and self:contains_element(x, depth + 1) then return true end
	end
	return false
end

local function copy_payload(v)
	if is_el(v) or type(v) ~= "table" then return v end
	local out = {}
	for k, x in pairs(v) do out[k] = copy_payload(x) end
	return out
end

function Mock:util()
	if self._util then return self._util end
	local f = assert(real_load(assert(io.open(self.root_dir .. "/shared/util.lua", "rb")):read("*a"), "@shared/util.lua"))
	self._util = f()
	return self._util
end

function Mock:json_decode()
	if self._jd then return self._jd end
	local f = assert(real_load(assert(io.open(self.root_dir .. "/shared/json_decode.lua", "rb")):read("*a"), "@shared/json_decode.lua"))
	self._jd = f()
	return self._jd
end

-- queue a remote event: to = "server" | "client"; sender = the player the server sees as `client` (only for client -> server)
function Mock:send_remote(to, name, source, sender, target_player, ...)
	local dir = to == "server" and "client->server" or "server->client"
	local ok = self:check_payload(name, dir, ...)
	if not ok then return false end
	local n = select("#", ...)
	local args = {}
	for i = 1, n do args[i] = copy_payload((select(i, ...))) end
	self.pending[#self.pending + 1] = { to = to, name = name, source = source, sender = sender, target = target_player, args = args, n = n, due = self.t + self.net_latency }
	local key = to .. ":" .. name
	if self.capture then
		local list = self.captured[key]
		if not list then list = {}; self.captured[key] = list end
		list[#list + 1] = { t = self.t, args = args, n = n, source = source, sender = sender }
	end
	return true
end

function Mock:deliver_net()
	if #self.pending == 0 then return end
	local q = self.pending
	self.pending = {}
	for _, item in ipairs(q) do
		if item.due > self.t then
			self.pending[#self.pending + 1] = item
		else
			local side = self.sides[item.to]
			if side and side.started then
				local reg = side.events[item.name]
				if not reg then
					self.net.dropped[#self.net.dropped + 1] = string.format("%s triggered %s event %s, but the event is not added there", item.to == "client" and "server" or "client", item.to, item.name)
					self.stats.remote_rejected = self.stats.remote_rejected + 1
				elseif not reg.remote then
					self.net.dropped[#self.net.dropped + 1] = string.format("%s event %s is not marked as remotely triggerable (addEvent(name, true))", item.to, item.name)
					self.stats.remote_rejected = self.stats.remote_rejected + 1
				elseif item.source and is_el(item.source) and item.source.destroyed then
					self.net.dropped[#self.net.dropped + 1] = "source element of " .. item.name .. " no longer exists"
				else
					self.net.delivered = self.net.delivered + 1
					side.client_ctx = item.sender
					self:trigger(side, item.name, item.source, unpack(item.args, 1, item.n))
					side.client_ctx = nil
				end
			end
		end
	end
end

-- captured payloads of one topic ("client:outbreak:events" ...): { { args, n, source, sender }, ... }
function Mock:sent(to, name) return self.captured[to .. ":" .. name] or {} end

-- every OUT event the server sent to the client, flattened, optionally filtered by type
function Mock:out_events(ev_type)
	local out = {}
	for _, item in ipairs(self:sent("client", "outbreak:events")) do
		for _, e in ipairs(item.args[1].events) do if not ev_type or e.type == ev_type then out[#out + 1] = e end end
	end
	return out
end

-- every IN event the client sent to the server, flattened, optionally filtered by type
function Mock:in_events(ev_type)
	local out = {}
	for _, item in ipairs(self:sent("server", "outbreak:in")) do
		for _, e in ipairs(item.args[1]) do if not ev_type or e.type == ev_type then out[#out + 1] = e end end
	end
	return out
end

-- a malicious or buggy client: triggers a server event as `sender` with ANY source element (MTA lets a client choose it)
function Mock:spoof_server_event(sender, name, source, ...)
	return self:send_remote("server", name, source, sender, nil, ...)
end

-- ------------------------------------------------------------------------------------------------------------------------ commands, keys, browser input
function Mock:command(side_name, who, name, ...)
	local list = self.commands[side_name]
	local c = list[name]
	if not c then error("no " .. side_name .. " command " .. name) end
	local side = self.sides[side_name]
	if c.restricted and who ~= self.console and not self.acl[tostring(who.name) .. ":command." .. name] then return false end
	local args = { ... }
	local ok, err = pcall(c.fn, who, name, unpack(args))
	if not ok then self.errors[#self.errors + 1] = string.format("[%s] command %s failed: %s", side_name, name, tostring(err)) end
	return true
end

function Mock:press_key(key, state)
	state = state or "down"
	for _, b in ipairs(self.binds) do
		if b.key == key and b.state == state and not b.removed then
			local ok, err = pcall(b.fn, key, state, unpack(b.args or {}))
			if not ok then self.errors[#self.errors + 1] = "bind " .. key .. " failed: " .. tostring(err) end
		end
	end
end

-- the page calls mta.triggerEvent('outbreak:ui', name, json): a LOCAL client event whose source is the browser element
function Mock:browser_trigger(name, data, raw_json)
	local client = self.sides.client
	local browser = self.browser
	assert(browser, "no browser was created")
	local json = raw_json
	if json == nil then
		package.path = self.root_dir .. "/?.lua;" .. package.path
		json = require("shared.json").encode(data or {})
	end
	return self:trigger(client, "outbreak:ui", browser, name, json)
end

-- the decoded {action, data} messages the Lua client pushed into the page, optionally by action
function Mock:ui_messages(action)
	local out = {}
	for _, msg in ipairs(self.browser_msgs) do if not action or msg.action == action then out[#out + 1] = msg end end
	return out
end

dofile(here .. "/mock_natives.lua")(Mock, { EL = EL, is_el = is_el, terrain = terrain })

return setmetatable(Mock, { __call = function(_, ...) return Mock.new(...) end })
