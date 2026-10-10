-- A small mock of the parts of Garry's Mod that Web Swing uses, for tests/glue_test.lua.
--
-- This is NOT Garry's Mod. It runs the addon's Lua in a sandbox environment (one per
-- realm: "server" / "client") where
--   * every GLOBAL the addon reads must exist in the mock (reading an unknown global is an
--     error: typos and wrong-realm functions fail loudly),
--   * every global the addon WRITES is recorded (leak check),
--   * hook.Add/hook.Run behave like GMod's (an error in a hook propagates; the first
--     non-nil return stops the chain),
--   * traces are ray casts against boxes + a ground plane,
--   * a movedata object and a Source-like integrator (half gravity, move, half gravity,
--     ground contact, friction) stand in for the engine's player movement.
-- What it cannot tell you: whether the real engine behaves like this integrator.

local G = {}
local sqrt, floor, abs, rad, sin, cos = math.sqrt, math.floor, math.abs, math.rad, math.sin, math.cos

---------------------------------------------------------------------------
-- Vector / Angle
---------------------------------------------------------------------------
local V = {}
V.__index = V
local function Vector(x, y, z)
	if type(x) == "table" then x, y, z = x.x, x.y, x.z end
	return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V)
end
V.__add = function(a, b) return Vector(a.x + b.x, a.y + b.y, a.z + b.z) end
V.__sub = function(a, b) return Vector(a.x - b.x, a.y - b.y, a.z - b.z) end
V.__mul = function(a, b)
	if type(a) == "number" then return Vector(a * b.x, a * b.y, a * b.z) end
	if type(b) == "number" then return Vector(a.x * b, a.y * b, a.z * b) end
	return Vector(a.x * b.x, a.y * b.y, a.z * b.z)
end
V.__div = function(a, b) return Vector(a.x / b, a.y / b, a.z / b) end
V.__unm = function(a) return Vector(-a.x, -a.y, -a.z) end
V.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
function V:Length() return sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2) end
function V:LengthSqr() return self.x ^ 2 + self.y ^ 2 + self.z ^ 2 end
function V:Dot(b) return self.x * b.x + self.y * b.y + self.z * b.z end
function V:Distance(b) return (self - b):Length() end
function V:GetNormalized() local l = self:Length() if l == 0 then return Vector() end return self / l end
function V:Set(b) self.x, self.y, self.z = b.x, b.y, b.z end
function V:ToScreen() return { x = 960 + self.x * 0.01, y = 540 - self.z * 0.01, visible = true } end
V.IsVector = true

local A = {}
A.__index = A
local function Angle(p, y, r) return setmetatable({ p = p or 0, y = y or 0, r = r or 0 }, A) end
function A:Forward()
	local p, y = rad(self.p), rad(self.y)
	return Vector(cos(p) * cos(y), cos(p) * sin(y), -sin(p))
end
function A:Right() local y = rad(self.y) return Vector(sin(y), -cos(y), 0) end
function A:Up() return Vector(0, 0, 1) end

---------------------------------------------------------------------------
-- A tiny bit library for plain Lua (LuaJIT has one)
---------------------------------------------------------------------------
local bitlib = rawget(_G, "bit")
if not bitlib then
	local function tobits(n)
		n = floor(n) % 4294967296
		local t = {}
		for i = 1, 32 do t[i] = n % 2 n = floor(n / 2) end
		return t
	end
	local function frombits(t)
		local n = 0
		for i = 32, 1, -1 do n = n * 2 + t[i] end
		return n
	end
	bitlib = {
		band = function(a, b) local x, y, r = tobits(a), tobits(b), {} for i = 1, 32 do r[i] = x[i] * y[i] end return frombits(r) end,
		bor = function(a, b) local x, y, r = tobits(a), tobits(b), {} for i = 1, 32 do r[i] = (x[i] + y[i] > 0) and 1 or 0 end return frombits(r) end,
	}
end

---------------------------------------------------------------------------
-- The mock world (traces)
---------------------------------------------------------------------------
-- boxes: { mins = {x,y,z}, maxs = {x,y,z}, ent = nil (world) or an entity table }
-- ground: z of an infinite floor (nil: none)
function G.newWorld()
	return { boxes = {}, ground = 0 }
end
function G.addBox(world, mins, maxs, ent)
	local b = { mins = mins, maxs = maxs, ent = ent }
	world.boxes[#world.boxes + 1] = b
	return b
end

local function rayBox(ox, oy, oz, dx, dy, dz, b)
	local tmin, tmax = 0, math.huge
	local nx, ny, nz = 0, 0, 0
	local o = { ox, oy, oz }
	local d = { dx, dy, dz }
	local lo = { b.mins[1], b.mins[2], b.mins[3] }
	local hi = { b.maxs[1], b.maxs[2], b.maxs[3] }
	local hitAxis, hitSign
	for i = 1, 3 do
		if abs(d[i]) < 1e-12 then
			if o[i] < lo[i] or o[i] > hi[i] then return nil end
		else
			local t1, t2 = (lo[i] - o[i]) / d[i], (hi[i] - o[i]) / d[i]
			local sign = -1
			if t1 > t2 then t1, t2 = t2, t1 sign = 1 end
			if t1 > tmin then tmin, hitAxis, hitSign = t1, i, sign end
			if t2 < tmax then tmax = t2 end
			if tmin > tmax then return nil end
		end
	end
	if not hitAxis then return nil, true end -- started inside
	local n = { 0, 0, 0 }
	n[hitAxis] = hitSign
	return tmin, false, n[1], n[2], n[3]
end

local function inside(b, x, y, z)
	return x >= b.mins[1] and x <= b.maxs[1] and y >= b.mins[2] and y <= b.maxs[2] and z >= b.mins[3] and z <= b.maxs[3]
end
G.inside = inside

---------------------------------------------------------------------------
-- The environment
---------------------------------------------------------------------------
local STD = { "math", "string", "table", "pairs", "ipairs", "pcall", "xpcall", "error", "assert", "type", "tostring", "tonumber",
	"select", "next", "unpack", "setmetatable", "getmetatable", "rawget", "rawset", "rawequal", "print", "os", "debug", "jit", "coroutine", "collectgarbage", "_VERSION" }

-- opts: world (G.newWorld()), now (starting CurTime)
function G.new(realm, root, opts)
	opts = opts or {}
	local isServer = realm == "server"
	local mock = {}
	local env = {}
	env.__realm = realm
	env.__leaks = {}
	env.__written = {}
	env.__errors = {}
	env.__cs = {}
	env.__sounds = {}
	env.__chat = {}
	env.__beams = 0
	env.__sprites = 0
	env.__world = opts.world or G.newWorld()
	env.__clock = { cur = opts.now or 100, real = opts.now or 100, tick = 1 / 66 }

	for _, k in ipairs(STD) do mock[k] = rawget(_G, k) end
	mock.bit = bitlib
	mock.SERVER, mock.CLIENT = isServer, not isServer
	mock.Vector, mock.Angle = Vector, Angle
	mock.vector_origin = Vector()
	mock.Color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end
	mock.color_white = mock.Color(255, 255, 255)
	mock.NULL = setmetatable({ __valid = false }, { __index = function(t, k) return function() return nil end end })

	-- constants (the real values where they matter)
	local const = {
		IN_ATTACK = 1, IN_JUMP = 2, IN_DUCK = 4, IN_FORWARD = 8, IN_BACK = 16, IN_USE = 32, IN_MOVELEFT = 512, IN_MOVERIGHT = 1024,
		IN_ATTACK2 = 2048, IN_RELOAD = 8192,
		MOVETYPE_NONE = 0, MOVETYPE_WALK = 2, MOVETYPE_NOCLIP = 8, MOVETYPE_LADDER = 9, MOVETYPE_OBSERVER = 10,
		MASK_SOLID = 33570827, MASK_SOLID_BRUSHONLY = 16395, MASK_PLAYERSOLID = 33636363,
		FCVAR_ARCHIVE = 128, FCVAR_REPLICATED = 8192, FCVAR_NOTIFY = 256,
		KEY_G = 17, KEY_V = 32, MOUSE_LEFT = 107, MOUSE_RIGHT = 108,
		TEXT_ALIGN_CENTER = 1, TEXT_ALIGN_TOP = 3, HUD_PRINTCONSOLE = 2,
	}
	for k, v in pairs(const) do mock[k] = v end

	-- time
	mock.CurTime = function() return env.__clock.cur end
	mock.RealTime = function() return env.__clock.real end
	mock.SysTime = function() return env.__clock.real end
	mock.FrameTime = function() return env.__clock.tick end
	mock.engine = { TickInterval = function() return env.__clock.tick end }
	mock.IsFirstTimePredicted = function() return rawget(env, "__predicted") ~= false end
	mock.IsValid = function(o)
		if o == nil or o == mock.NULL or type(o) ~= "table" then return false end
		return o.__valid ~= false
	end
	mock.ErrorNoHalt = function(s) env.__errors[#env.__errors + 1] = tostring(s) end
	mock.MsgC = function() end
	mock.AddCSLuaFile = function(f) env.__cs[#env.__cs + 1] = f end
	mock.rawget = rawget
	mock.game = { SinglePlayer = function() return false end, GetWorld = function() return env.__worldEnt end }

	-- the world entity (what a trace says it hit for brushes)
	env.__worldEnt = { class = "worldspawn", __valid = true, IsWorld = function() return true end, IsPlayer = function() return false end,
		IsWeapon = function() return false end, GetClass = function() return "worldspawn" end }
	env.__worldEnt.__index = env.__worldEnt

	-- hooks (as GMod: first non-nil return wins; no pcall)
	local hooks = {}
	env.__hooks = hooks
	mock.hook = {
		Add = function(ev, id, fn)
			assert(type(id) == "string" or type(id) == "table", "hook id must be a string")
			assert(type(fn) == "function", "hook function expected")
			hooks[ev] = hooks[ev] or {}
			hooks[ev][id] = fn
		end,
		Remove = function(ev, id) if hooks[ev] then hooks[ev][id] = nil end end,
		Run = function(ev, ...)
			local t = hooks[ev]
			if not t then return end
			local ids = {}
			for id in pairs(t) do ids[#ids + 1] = id end
			table.sort(ids)
			for _, id in ipairs(ids) do
				local r = t[id](...)
				if r ~= nil then return r end
			end
		end,
	}

	-- convars
	local convars, callbacks = {}, {}
	env.__convars = convars
	local function mkcv(name, default, min, max)
		local cv = { name = name, value = tostring(default), min = min, max = max }
		function cv:GetName() return self.name end
		function cv:GetString() return self.value end
		function cv:GetFloat() return tonumber(self.value) or 0 end
		function cv:GetInt() return floor(tonumber(self.value) or 0) end
		function cv:GetBool() return (tonumber(self.value) or 0) ~= 0 end
		function cv:SetValue(v)
			v = tostring(v)
			if self.value == v then return end
			local old = self.value
			self.value = v
			for _, cb in ipairs(callbacks[self.name] or {}) do cb(self.name, old, v) end
		end
		convars[name] = convars[name] or cv
		return convars[name]
	end
	mkcv("sv_gravity", 600)
	mkcv("sv_maxvelocity", 3500)
	mock.CreateConVar = function(name, default, flags, help, min, max)
		assert(isServer or true)
		return mkcv(name, default, min, max)
	end
	if not isServer then
		mock.CreateClientConVar = function(name, default, save, userinfo, help, min, max) return mkcv(name, default, min, max) end
	end
	mock.GetConVar = function(name) return convars[name] end
	mock.cvars = { AddChangeCallback = function(name, fn) callbacks[name] = callbacks[name] or {} table.insert(callbacks[name], fn) end }

	-- net
	local netState = { out = nil, recv = {}, strings = {} }
	env.__net = netState
	env.__outbox = {}
	mock.util = {}
	mock.util.AddNetworkString = function(n) assert(isServer, "AddNetworkString is server only") netState.strings[n] = true end
	local function writer(kind) return function(v) netState.out.data[#netState.out.data + 1] = { kind, v } end end
	mock.net = {
		Start = function(name) netState.out = { name = name, data = {} } end,
		WriteUInt = writer("uint"), WriteFloat = writer("float"), WriteBool = writer("bool"), WriteEntity = writer("ent"),
		WriteVector = writer("vec"), WriteString = writer("str"), WriteInt = writer("int"),
		SendToServer = function() assert(not isServer) env.__outbox[#env.__outbox + 1] = netState.out netState.out = nil end,
		Send = function() netState.out = nil end,
		Broadcast = function() netState.out = nil end,
		Receive = function(name, fn) netState.recv[name] = fn end,
	}
	local rd
	local function reader(kind) return function() local e = rd.data[rd.i] rd.i = rd.i + 1 assert(e and e[1] == kind, "net read mismatch: wanted " .. kind .. " got " .. tostring(e and e[1])) return e[2] end end
	mock.net.ReadUInt, mock.net.ReadFloat, mock.net.ReadBool, mock.net.ReadEntity = reader("uint"), reader("float"), reader("bool"), reader("ent")
	mock.net.ReadVector, mock.net.ReadString, mock.net.ReadInt = reader("vec"), reader("str"), reader("int")
	-- deliver a message that another realm's outbox holds
	function env.__deliver(msg, ply)
		rd = { data = msg.data, i = 1 }
		local fn = netState.recv[msg.name]
		assert(fn, "no net.Receive for " .. msg.name)
		fn(#msg.data, ply)
	end

	-- traces
	local function filterAllows(f, ent)
		if f == nil then return true end
		if type(f) == "function" then return f(ent) end
		if type(f) == "table" and f.class then return f ~= ent end
		if type(f) == "table" then for _, e in ipairs(f) do if e == ent then return false end end end
		return true
	end
	mock.util.TraceLine = function(data)
		local out = data.output or {}
		for k in pairs(out) do out[k] = nil end
		local sx, sy, sz = data.start.x, data.start.y, data.start.z
		local ex, ey, ez = data.endpos.x, data.endpos.y, data.endpos.z
		local dx, dy, dz = ex - sx, ey - sy, ez - sz
		local len = sqrt(dx * dx + dy * dy + dz * dz)
		out.Hit, out.Fraction, out.StartSolid, out.HitSky, out.HitWorld, out.HitNoDraw = false, 1, false, false, false, false
		out.HitPos, out.HitNormal, out.Entity = Vector(ex, ey, ez), Vector(0, 0, 0), mock.NULL
		if len < 1e-9 then return out end
		local ux, uy, uz = dx / len, dy / len, dz / len
		local best, bn, bent = len, nil, nil
		local world = env.__world
		if world.ground and uz < -1e-9 then
			local t = (world.ground - sz) / uz
			if t >= 0 and t < best then best, bn, bent = t, { 0, 0, 1 }, env.__worldEnt end
		end
		for _, b in ipairs(world.boxes) do
			local ent = b.ent or env.__worldEnt
			if filterAllows(data.filter, ent) then
				local t, starts, nx, ny, nz = rayBox(sx, sy, sz, ux, uy, uz, b)
				if starts then out.StartSolid = true end
				if t and t < best then best, bn, bent = t, { nx, ny, nz }, ent end
			end
		end
		if bn then
			out.Hit, out.Fraction = true, best / len
			out.HitPos = Vector(sx + ux * best, sy + uy * best, sz + uz * best)
			out.HitNormal = Vector(bn[1], bn[2], bn[3])
			out.Entity = bent
			out.HitWorld = bent == env.__worldEnt
		end
		return out
	end
	mock.util.TraceHull = function(data)
		local out = data.output or {}
		for k in pairs(out) do out[k] = nil end
		out.Hit, out.StartSolid, out.Fraction = false, false, 1
		local x, y, z = data.start.x, data.start.y, data.start.z
		local mn, mx = data.mins, data.maxs
		local world = env.__world
		if world.ground and z + mn.z < world.ground - 0.01 then out.Hit, out.StartSolid = true, true end
		for _, b in ipairs(world.boxes) do
			if x + mx.x > b.mins[1] and x + mn.x < b.maxs[1] and y + mx.y > b.mins[2] and y + mn.y < b.maxs[2]
				and z + mx.z > b.mins[3] and z + mn.z < b.maxs[3] then
				out.Hit, out.StartSolid = true, true
			end
		end
		return out
	end

	-- misc libs
	mock.concommand = { Add = function(name, fn) rawset(env, "__concommands", rawget(env, "__concommands") or {}) env.__concommands[name] = fn end }
	mock.gameevent = { Listen = function() end }
	mock.player = {
		GetAll = function() return rawget(env, "__players") or {} end,
		Iterator = function() return ipairs(rawget(env, "__players") or {}) end,
	}
	mock.file = { Exists = function() return true end }
	mock.timer = { Simple = function() end }
	mock.HUD_PRINTCONSOLE = 2

	-- client-only
	if not isServer then
		mock.LocalPlayer = function() return rawget(env, "__localPlayer") end
		mock.Material = function(name) return { name = name, IsError = function() return false end } end
		mock.render = {
			SetMaterial = function() end, StartBeam = function() env.__beamOpen = true end, EndBeam = function() env.__beamOpen = false env.__beams = env.__beams + 1 end,
			AddBeam = function(v) assert(type(v.x) == "number") end, DrawSprite = function() env.__sprites = env.__sprites + 1 end,
		}
		mock.surface = { CreateFont = function() end, DrawCircle = function() end, SetDrawColor = function() end, DrawRect = function() end, DrawOutlinedRect = function() end }
		mock.draw = { SimpleText = function(text) env.__lastText = text end }
		mock.ScrW, mock.ScrH = function() return 1920 end, function() return 1080 end
		mock.chat = { AddText = function(...) env.__chat[#env.__chat + 1] = { ... } end }
		mock.input = { IsButtonDown = function(code) local k = rawget(env, "__keysDown") return k and k[code] or false end }
		mock.gui = { IsGameUIVisible = function() return false end, IsConsoleVisible = function() return false end }
		mock.vgui = { CursorVisible = function() return false end, GetKeyboardFocus = function() return nil end }
		mock.system = { HasFocus = function() return true end }
	else
		mock.player.GetAll = mock.player.GetAll
	end

	-- the environment table: strict reads, recorded writes
	local allowedWrites = { WebSwing = true, SWEP = true }
	setmetatable(env, {
		__index = function(t, k)
			local v = mock[k]
			if v ~= nil then return v end
			if k == "_G" then return t end
			if k == "WebSwing" or k == "SkateGM" or k == "SKATEGM_UI" then return nil end -- legitimately nil until defined
			error("undefined global '" .. tostring(k) .. "' read (" .. realm .. " realm)", 2)
		end,
		__newindex = function(t, k, v)
			if not allowedWrites[k] then env.__leaks[#env.__leaks + 1] = tostring(k) end
			rawset(t, k, v)
		end,
	})
	rawset(env, "__mock", mock)

	-- include(): relative to lua/
	mock.include = function(path)
		return G.run(env, root .. "/lua/" .. path)
	end
	return env
end

function G.run(env, file)
	local chunk, err = loadfile(file)
	assert(chunk, err)
	if setfenv then setfenv(chunk, env) else error("this test harness needs Lua 5.1 or LuaJIT (setfenv)") end
	return chunk()
end

function G.loadAddon(env, root)
	G.run(env, root .. "/lua/autorun/webswing_init.lua")
	return env.WebSwing
end

function G.loadWeapon(env, root)
	rawset(env, "SWEP", { Primary = {}, Secondary = {} })
	G.run(env, root .. "/lua/weapons/weapon_webswing.lua")
	return rawget(env, "SWEP")
end

---------------------------------------------------------------------------
-- Entities, players, movedata
---------------------------------------------------------------------------
-- A prop: a box that can move. (Translation only; the world<->local transform is exact.)
function G.newProp(env, class, pos)
	local e = { class = class or "prop_physics", origin = Vector(pos[1], pos[2], pos[3]), __valid = true, nw = {} }
	e.IsWorld = function() return false end
	e.IsPlayer = function() return false end
	e.IsNPC = function() return class == "npc_citizen" end
	e.IsNextBot = function() return false end
	e.IsWeapon = function() return false end
	e.GetClass = function(self) return self.class end
	e.GetPos = function(self) return Vector(self.origin) end
	e.WorldToLocal = function(self, v) return v - self.origin end
	e.LocalToWorld = function(self, v) return v + self.origin end
	e.GetPhysicsObject = function(self)
		local ph = self.phys or { mass = 50, impulses = {} }
		self.phys = ph
		ph.IsValid = function() return true end
		ph.IsMotionEnabled = function() return true end
		ph.GetMass = function() return ph.mass end
		ph.ApplyForceOffset = function(_, f, p) ph.impulses[#ph.impulses + 1] = { f = Vector(f), p = Vector(p) } end
		return ph
	end
	return e
end

local weaponMeta = {}
function G.newWeapon(env, class)
	return { class = class or "weapon_webswing", IsWebSwing = (class or "weapon_webswing") == "weapon_webswing", __valid = true, GetClass = function(self) return self.class end }
end

local PM = {}
PM.__index = PM
function G.newPlayer(env, pos, opts)
	opts = opts or {}
	local p = setmetatable({
		class = "player", origin = Vector(pos[1], pos[2], pos[3]), vel = Vector(), __valid = true, alive = true,
		movetype = 2, vehicle = false, water = 0, frozen = false, crouch = false, onGround = true, gravity = 1,
		eye = Angle(0, 0, 0), weapon = nil, nw = {}, buttons = 0, oldButtons = 0, name = opts.name or "Player", sounds = {},
	}, PM)
	p.movetype = 2 -- MOVETYPE_WALK
	return p
end
function PM:IsWorld() return false end
function PM:IsPlayer() return true end
function PM:IsNPC() return false end
function PM:IsWeapon() return false end
function PM:IsNextBot() return false end
function PM:GetClass() return "player" end
function PM:Alive() return self.alive end
function PM:GetMoveType() return self.movetype end
function PM:InVehicle() return self.vehicle end
function PM:WaterLevel() return self.water end
function PM:IsFrozen() return self.frozen end
function PM:Crouching() return self.crouch end
function PM:IsOnGround() return self.onGround end
function PM:GetGravity() return self.gravity end
function PM:GetActiveWeapon() return self.weapon or G.NULL end
function PM:GetShootPos() return Vector(self.origin.x, self.origin.y, self.origin.z + (self.crouch and 28 or 64)) end
function PM:EyePos() return self:GetShootPos() end
function PM:EyeAngles() return Angle(self.eye.p, self.eye.y, 0) end
function PM:GetPos() return Vector(self.origin) end
function PM:GetVelocity() return Vector(self.vel) end
function PM:Nick() return self.name end
function PM:Ping() return 40 end
function PM:IsAdmin() return false end
function PM:IsDormant() return false end
function PM:EntIndex() return self.id or 1 end
function PM:ShouldDrawLocalPlayer() return self.thirdperson == true end
function PM:GetViewModel() return G.NULL end
function PM:LookupAttachment() return 0 end
function PM:LookupBone() return nil end
function PM:GetBonePosition() return nil end
function PM:EmitSound(path, level, pitch, volume) self.sounds[#self.sounds + 1] = path end
function PM:SetNW2Int(k, v) self.nw[k] = v end
function PM:SetNW2Float(k, v) self.nw[k] = v end
function PM:SetNW2Bool(k, v) self.nw[k] = v end
function PM:SetNW2Vector(k, v) self.nw[k] = Vector(v) end
function PM:SetNW2Entity(k, v) self.nw[k] = v end
function PM:GetNW2Int(k, d) local v = self.nw[k] if v == nil then return d end return v end
PM.GetNW2Float, PM.GetNW2Bool = PM.GetNW2Int, PM.GetNW2Int
function PM:GetNW2Vector(k, d) local v = self.nw[k] if v == nil then return d or Vector() end return v end
function PM:GetNW2Entity(k) local v = self.nw[k] if v == nil then return G.NULL end return v end
function PM:ChatPrint() end
function PM:PrintMessage() end
function PM:Give(c) self.weapon = G.newWeapon(nil, c) end
function PM:SelectWeapon() end

G.NULL = setmetatable({ __valid = false }, { __index = function() return function() end end })

-- movedata
local MV = {}
MV.__index = MV
function G.newMove(ply, buttons, oldButtons)
	return setmetatable({ origin = Vector(ply.origin), vel = Vector(ply.vel), buttons = buttons or 0, old = oldButtons or 0,
		ang = Angle(ply.eye.p, ply.eye.y, 0) }, MV)
end
function MV:GetOrigin() return Vector(self.origin) end
function MV:SetOrigin(v) self.origin = Vector(v) end
function MV:GetVelocity() return Vector(self.vel) end
function MV:SetVelocity(v) self.vel = Vector(v) end
function MV:GetButtons() return self.buttons end
function MV:GetOldButtons() return self.old end
function MV:GetAngles() return Angle(self.ang.p, self.ang.y, 0) end
function MV:KeyDown(k) return bitlib.band(self.buttons, k) ~= 0 end

-- a Source-like player integrator: half gravity, move, half gravity; ground; friction
function G.engineStep(env, ply, mv, dt, opts)
	opts = opts or {}
	local g = env.__convars.sv_gravity:GetFloat() * (ply.gravity ~= 0 and ply.gravity or 1)
	local v, o = mv.vel, mv.origin
	if ply.onGround and (v.z <= 140) and not opts.noFriction then
		local k = math.max(0, 1 - 8 * dt) -- ground friction
		v.x, v.y = v.x * k, v.y * k
	end
	v.z = v.z - 0.5 * g * dt
	local nx, ny, nz = o.x + v.x * dt, o.y + v.y * dt, o.z + v.z * dt
	-- boxes: stop at the face (the player's centre point stands in for the hull)
	for _, b in ipairs(env.__world.boxes) do
		if G.inside(b, nx, ny, nz + 40) and not G.inside(b, o.x, o.y, o.z + 40) then
			nx, ny, nz = o.x, o.y, o.z
			v.x, v.y, v.z = 0, 0, math.min(0, v.z)
			rawset(env, "__bumps", (rawget(env, "__bumps") or 0) + 1)
			break
		end
	end
	local ground = env.__world.ground or -1e9
	if nz <= ground then nz = ground if v.z < 0 then v.z = 0 end end
	o.x, o.y, o.z = nx, ny, nz
	v.z = v.z - 0.5 * g * dt
	ply.onGround = (nz <= ground + 0.01) and v.z <= 140
	if ply.onGround and v.z < 0 then v.z = 0 end
	ply.origin, ply.vel = Vector(o), Vector(v)
end

-- one usercmd: SetupMove hooks, then the engine
function G.tick(env, ply, buttons, opts)
	opts = opts or {}
	local mv = G.newMove(ply, buttons, ply.oldButtons or 0)
	env.hook.Run("SetupMove", ply, mv, {})
	G.engineStep(env, ply, mv, env.__clock.tick, opts)
	ply.oldButtons = buttons
	env.__clock.cur = env.__clock.cur + env.__clock.tick
	env.__clock.real = env.__clock.real + env.__clock.tick
	return mv
end

return G
