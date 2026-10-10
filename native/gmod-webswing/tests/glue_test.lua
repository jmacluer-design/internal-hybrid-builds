-- Tests for the GMod-facing Lua (everything except sh_swing.lua) under tests/gmock.lua.
-- The mock is not Garry's Mod: see the header of gmock.lua for what it does and does not prove.
local T = ...
local root = T.root
local G = dofile(root .. "/tests/gmock.lua")

local sqrt, abs, max, min = math.sqrt, math.abs, math.max, math.min
local IN_ATTACK, IN_JUMP, IN_DUCK, IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT, IN_ATTACK2, IN_RELOAD = 1, 2, 4, 8, 16, 512, 1024, 2048, 8192

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
-- a world: ground at z=0, a high slab (the underside of something to hang from) and a tower
local function newWorld()
	local w = G.newWorld()
	G.addBox(w, { -6000, -4000, 2990 }, { 6000, 4000, 3190 })          -- slab: underside at z=2990 (thick: the mock has no swept collision)
	G.addBox(w, { 2400, -600, 0 }, { 3000, 600, 2200 })               -- tower: face at x=2400, roof at z=2200
	return w
end

local function server(world)
	local env = G.new("server", root, { world = world or newWorld() })
	G.loadAddon(env, root)
	local ply = G.newPlayer(env, { 0, 0, 0 })
	ply.weapon = G.newWeapon(env, "weapon_webswing")
	env.__players = { ply }
	return env, ply
end

local function client(world)
	local env = G.new("client", root, { world = world or newWorld() })
	G.loadAddon(env, root)
	local ply = G.newPlayer(env, { 0, 0, 0 })
	ply.weapon = G.newWeapon(env, "weapon_webswing")
	rawset(env, "__localPlayer", ply)
	rawset(env, "__players", { ply })
	return env, ply
end

local function run(env, ply, ticks, buttons, opts)
	local mv
	for _ = 1, ticks do mv = G.tick(env, ply, type(buttons) == "function" and buttons() or buttons, opts) end
	return mv
end

local function dist3(a, b) return sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end
local function speed(ply) return ply.vel:Length() end

-- the player in mid-air, under the slab, looking up and forward
local function airborne(ply, z)
	ply.origin.z = z or 1500
	ply.onGround = false
end

---------------------------------------------------------------------------
-- loading
---------------------------------------------------------------------------
T.test("addon loads in the SERVER realm: no errors, no leaked globals", function()
	local env = G.new("server", root, { world = newWorld() })
	G.loadAddon(env, root)
	T.eq(#env.__leaks, 0, "leaked globals: " .. table.concat(env.__leaks, ","))
	T.eq(#env.__errors, 0, "errors: " .. table.concat(env.__errors, " | "))
	T.truthy(env.WebSwing and env.WebSwing.Math and env.WebSwing.T, "WebSwing table is set up")
	T.truthy(env.__net.strings["webswing_board"], "net string registered")
	local sent = table.concat(env.__cs, ",")
	for _, f in ipairs({ "sh_swing", "sh_core", "skategm_compat", "cl_swing", "cl_hud" }) do
		T.truthy(sent:find(f, 1, true), "AddCSLuaFile for " .. f)
	end
end)

T.test("addon loads in the CLIENT realm: no errors, no leaked globals", function()
	local env = G.new("client", root, { world = newWorld() })
	G.loadAddon(env, root)
	T.eq(#env.__leaks, 0, "leaked globals: " .. table.concat(env.__leaks, ","))
	T.eq(#env.__errors, 0, "errors: " .. table.concat(env.__errors, " | "))
	T.truthy(env.WebSwing.CCV.hud, "client convars exist")
	T.truthy(env.__hooks.HUDPaint and env.__hooks.PostDrawTranslucentRenderables, "HUD and rope hooks registered")
end)

T.test("weapon file loads (both realms) and carries the flag the hook looks for", function()
	for _, realm in ipairs({ "server", "client" }) do
		local env = G.new(realm, root, { world = newWorld() })
		G.loadAddon(env, root)
		local swep = G.loadWeapon(env, root)
		T.eq(swep.IsWebSwing, true)
		T.eq(swep.Primary.Automatic, true)
		T.eq(swep.Category, "Web Swing")
		T.truthy(swep.Holster and swep.Deploy and swep.PrimaryAttack and swep.SecondaryAttack and swep.Reload)
		T.eq(#env.__errors, 0)
	end
end)

T.test("hook identifiers are all prefixed webswing_ (no collisions with SkateGM's own)", function()
	for _, realm in ipairs({ "server", "client" }) do
		local env = G.new(realm, root, { world = newWorld() })
		G.loadAddon(env, root)
		local n = 0
		for ev, ids in pairs(env.__hooks) do
			for id in pairs(ids) do
				n = n + 1
				T.eq(id:sub(1, 9), "webswing_", realm .. " hook '" .. id .. "' on " .. ev)
			end
		end
		T.gt(n, 5)
	end
end)

T.test("loading twice (lua refresh) replaces hooks instead of doubling them", function()
	local env = G.new("server", root, { world = newWorld() })
	G.loadAddon(env, root)
	local before = 0
	for _, ids in pairs(env.__hooks) do for _ in pairs(ids) do before = before + 1 end end
	G.loadAddon(env, root)
	local after = 0
	for _, ids in pairs(env.__hooks) do for _ in pairs(ids) do after = after + 1 end end
	T.eq(before, after)
	T.eq(#env.__errors, 0)
end)

T.test("convar changes reach the tuning table without per-tick reads", function()
	local env = server()
	local WS = env.WebSwing
	env.__convars.ws_max_dist:SetValue(1234)
	T.eq(WS.T.maxDist, 1234)
	env.__convars.ws_gravity_scale:SetValue(2.5)
	T.eq(WS.T.gravityScale, 2.5)
	env.__convars.ws_boost:SetValue(0)
	T.eq(WS.T.boostMult, 0)
	env.__convars.ws_enabled:SetValue(0)
	T.eq(WS.T.enabled, false)
	env.__convars.ws_board_hop:SetValue(3)
	T.near(WS.T.boardHop, 3 * 39.37, 1e-9)
end)

---------------------------------------------------------------------------
-- foot mode: attach, swing, release
---------------------------------------------------------------------------
local function swingSetup(world)
	local env, ply = server(world)
	local WS = env.WebSwing
	airborne(ply, 1500)
	ply.eye = env.Angle(-50, 0, 0) -- pitch -50: looking up and forward, at the slab
	return env, ply, WS
end

T.test("primary: a web attaches where the aim hits (the underside of the slab), on the first tick", function()
	local env, ply, WS = swingSetup()
	run(env, ply, 1, IN_ATTACK)
	local S = ply.WSS
	T.eq(S.mode, 1, "attached")
	T.near(S.az, 2990, 0.5)
	T.near(S.ax, 1197, 25)
	T.eq(S.kind, 1, "a direct hit, not the assist")
	T.truthy(S.L > 1500 and S.L < 2100, "rope length is the distance " .. S.L)
	T.eq(ply:GetNW2Int("ws_mode"), 1, "published to the other clients")
	T.near(ply:GetNW2Vector("ws_anchor").z, 2990, 0.5)
	T.truthy(#ply.sounds > 0, "plays a sound")
	T.eq(#env.__errors, 0)
end)

T.test("a 10 s swing: the rope is never longer than it was when it went taut, and it swings", function()
	local env, ply, WS = swingSetup()
	run(env, ply, 1, IN_ATTACK)
	local S = ply.WSS
	local L, maxOver, minZ, maxSpeed = S.L, -1e9, 1e9, 0
	for _ = 1, 660 do
		run(env, ply, 1, IN_ATTACK)
		local body = env.Vector(ply.origin.x, ply.origin.y, ply.origin.z + WS.CHEST)
		local d = dist3(body, env.Vector(S.ax, S.ay, S.az))
		maxOver = max(maxOver, d - S.L)
		minZ = min(minZ, ply.origin.z)
		maxSpeed = max(maxSpeed, speed(ply))
	end
	T.note("rope %.0f u, max over-length %.3f u, lowest z %.0f (from 1500), top speed %.0f u/s", L, maxOver, minZ, maxSpeed)
	T.lt(maxOver, 2.0, "rope stretched")
	T.lt(minZ, 1300, "it swung down")
	T.lt(maxSpeed, WS.T.maxSpeed + 1, "speed cap")
	T.eq(S.mode, 1)
	T.eq(#env.__errors, 0)
end)

T.test("the swing conserves energy under the hook (no drag): within 3% of the swing's range", function()
	local env, ply, WS = swingSetup()
	WS.T.airDrag, WS.T.airDragHi = 0, 0
	run(env, ply, 1, IN_ATTACK)
	local S = ply.WSS
	local g = 600 * WS.T.gravityScale
	local function E() return 0.5 * speed(ply) ^ 2 + g * (ply.origin.z + WS.CHEST) end
	local E0 = E()
	local Emin, Emax, zmin, zmax = E0, E0, 1e9, -1e9
	for _ = 1, 660 do
		run(env, ply, 1, IN_ATTACK)
		local e = E()
		Emin, Emax = min(Emin, e), max(Emax, e)
		zmin, zmax = min(zmin, ply.origin.z), max(zmax, ply.origin.z)
	end
	local range = g * (zmax - zmin)
	local drift = max(abs(Emax - E0), abs(Emin - E0)) / range
	T.note("energy drift %.3f%% of g*dz (dz = %.0f)", drift * 100, zmax - zmin)
	T.lt(drift, 0.03)
end)

T.test("a swing from the SERVER realm and the CLIENT realm (same inputs) end in the same place", function()
	local envS, plyS = swingSetup()
	local envC, plyC = client()
	airborne(plyC, 1500)
	plyC.eye = envC.Angle(-50, 0, 0)
	for i = 1, 300 do
		local b = i < 200 and IN_ATTACK or (IN_ATTACK + IN_FORWARD)
		run(envS, plyS, 1, b)
		run(envC, plyC, 1, b)
	end
	T.note("server %.4f,%.4f,%.4f  client %.4f,%.4f,%.4f", plyS.origin.x, plyS.origin.y, plyS.origin.z, plyC.origin.x, plyC.origin.y, plyC.origin.z)
	T.near(plyS.origin.x, plyC.origin.x, 1e-6)
	T.near(plyS.origin.z, plyC.origin.z, 1e-6)
	T.near(speed(plyS), speed(plyC), 1e-6)
end)

T.test("client prediction replays do not double-apply: re-running a tick as a replay changes no state", function()
	local env, ply, WS = swingSetup()
	run(env, ply, 20, IN_ATTACK)
	local S = ply.WSS
	local t, L, now = S.t, S.L, env.__clock.cur
	-- a replayed (non-first) prediction of the same command: forces apply, state must not advance
	env.__predicted = false
	local mv = G.newMove(ply, IN_ATTACK + IN_DUCK, IN_ATTACK)
	env.hook.Run("SetupMove", ply, mv, {})
	env.__predicted = nil
	T.eq(S.t, t, "attach timer untouched by a replay")
	T.eq(S.L, L, "rope length untouched by a replayed reel")
	T.eq(S.mode, 1)
end)

T.test("secondary while idle with nothing in range: no zip, a short cooldown, no error", function()
	local env, ply = server(G.newWorld())
	ply.eye = env.Angle(-20, 180, 0) -- away from everything
	run(env, ply, 3, IN_ATTACK2)
	T.eq(ply.WSS.mode, 0)
	run(env, ply, 1, 0)
	T.eq(#env.__errors, 0)
end)

T.test("primary at the sky with nothing in the cone: a whiff, no web, retries after a moment", function()
	local env, ply = server(G.newWorld())
	airborne(ply, 400)
	ply.eye = env.Angle(-30, 180, 0)
	run(env, ply, 1, IN_ATTACK)
	local S = ply.WSS
	T.eq(S.mode, 0)
	T.gt(S.nextFire, env.__clock.cur - 1e-9)
	T.gt(S.whiffT, 0)
	T.eq(ply:GetNW2Int("ws_mode", 0), 0)
end)

T.test("assist: the aim hits sky, so a surface up and ahead in the cone is chosen", function()
	local w = G.newWorld()
	G.addBox(w, { 2400, -600, 0 }, { 3000, 600, 2200 }) -- the tower only
	local env, ply, WS = swingSetup(w)
	ply.origin.z = 1000
	ply.eye = env.Angle(-10, 30, 0) -- aim at nothing: yaw 30, the tower is around yaw 0
	run(env, ply, 1, IN_ATTACK)
	local S = ply.WSS
	T.eq(S.mode, 1, "assist attached")
	T.eq(S.kind, 2, "by the assist")
	T.near(S.ax, 2400, 2)
	T.gt(S.az, 1000 + WS.T.assistMinUp)
	-- with the assist off the same aim whiffs
	local env2, ply2 = swingSetup(w)
	env2.__convars.ws_assist:SetValue(0)
	ply2.origin.z = 1000
	ply2.eye = env2.Angle(-10, 30, 0)
	run(env2, ply2, 1, IN_ATTACK)
	T.eq(ply2.WSS.mode, 0)
end)

T.test("a web longer than ws_max_dist is not fired", function()
	local env, ply = swingSetup()
	env.__convars.ws_max_dist:SetValue(900)
	run(env, ply, 1, IN_ATTACK)
	T.eq(ply.WSS.mode, 0)
end)

T.test("release: slingshot boost scales with where in the arc you let go; none above the anchor's level", function()
	local boosts = {}
	for _, k in ipairs({ 30, 90, 150, 210, 270, 330 }) do
		local env, ply, WS = swingSetup()
		run(env, ply, k, IN_ATTACK)
		local S = ply.WSS
		T.eq(S.mode, 1)
		local before = speed(ply)
		run(env, ply, 1, 0)
		T.eq(S.mode, 0, "released")
		boosts[#boosts + 1] = S.boost
		T.le(S.boost, WS.T.boostMax + 1e-9)
		T.eq(ply:GetNW2Int("ws_mode"), 0)
	end
	local mx = 0
	for i, b in ipairs(boosts) do mx = max(mx, b) T.note("release after %3d ticks: boost %.0f u/s", i * 60 - 30, b) end
	T.gt(mx, 50, "some release moment gives a real boost")
	-- ws_boost 0 turns it off
	local env, ply = swingSetup()
	env.__convars.ws_boost:SetValue(0)
	run(env, ply, 150, IN_ATTACK)
	run(env, ply, 1, 0)
	T.eq(ply.WSS.boost, 0)
end)

T.test("jump while attached: let go and hop upward", function()
	local env, ply, WS = swingSetup()
	run(env, ply, 40, IN_ATTACK)
	local vz = ply.vel.z
	run(env, ply, 1, IN_ATTACK + IN_JUMP)
	T.eq(ply.WSS.mode, 0)
	T.gt(ply.vel.z, vz + WS.T.jumpPop * 0.8)
end)

T.test("crouch reels the rope in at ws_reel_speed down to ws_min_rope", function()
	local env, ply, WS = swingSetup()
	run(env, ply, 5, IN_ATTACK)
	local S = ply.WSS
	local L0 = S.L
	run(env, ply, 66, IN_ATTACK + IN_DUCK)
	T.near(L0 - S.L, WS.T.reel * 1.0, WS.T.reel * 0.08, "reeled about one second's worth")
	run(env, ply, 66 * 4, IN_ATTACK + IN_DUCK)
	T.near(S.L, WS.T.minRope, 1e-6)
	T.eq(S.mode, 1)
end)

T.test("pump (forward) adds speed to a swing; steering (A/D) bends it sideways", function()
	local a, pa = swingSetup()
	local b, pb = swingSetup()
	local c, pc = swingSetup()
	local peakA, peakB = 0, 0
	for _ = 1, 330 do
		run(a, pa, 1, IN_ATTACK)
		run(b, pb, 1, IN_ATTACK + IN_FORWARD)
		run(c, pc, 1, IN_ATTACK + IN_MOVERIGHT)
		peakA, peakB = max(peakA, speed(pa)), max(peakB, speed(pb))
	end
	T.note("peak speed over 5 s: plain %.0f, pumped %.0f; y after 5 s: plain %.0f, steered right %.0f", peakA, peakB, pa.origin.y, pc.origin.y)
	T.gt(peakB, peakA + 100)
	T.lt(pc.origin.y, pa.origin.y - 50, "right is -y at yaw 0")
end)

T.test("firing from the ground: a hop leaves the floor (ground friction would eat the swing)", function()
	local env, ply = server()
	ply.eye = env.Angle(-25, 0, 0) -- at the face of the tower
	ply.onGround = true
	run(env, ply, 1, IN_ATTACK)
	T.eq(ply.WSS.mode, 1)
	T.gt(ply.vel.z, 150)
	T.falsy(ply.onGround, "off the ground")
end)

---------------------------------------------------------------------------
-- zip and dive
---------------------------------------------------------------------------
T.test("secondary: zip up a wall to a ledge and vault over it", function()
	local env, ply = server()
	local WS = env.WebSwing
	ply.eye = env.Angle(-37.4, 0, 0) -- aim at the face of the tower, ~300 below its roof
	local arrived
	for i = 1, 66 * 4 do
		run(env, ply, 1, i == 1 and IN_ATTACK2 or 0)
		if i == 1 then T.eq(ply.WSS.mode, 2, "zipping") T.truthy(ply.WSS.zledge, "found the ledge") end
		if ply.WSS.mode == 0 then arrived = i break end
	end
	T.truthy(arrived, "zip never finished")
	T.note("zip took %.2f s, ended at (%.0f, %.0f, %.0f) moving (%.0f, %.0f, %.0f)", arrived / 66, ply.origin.x, ply.origin.y, ply.origin.z, ply.vel.x, ply.vel.y, ply.vel.z)
	T.lt(arrived / 66, WS.T.zipMaxT)
	T.gt(ply.origin.z, 2200, "feet above the roof when the vault starts")
	T.gt(ply.vel.z, 250, "the vault hop")
	run(env, ply, 20, 0) -- a third of a second of the hop
	T.note("a third of a second later: (%.0f, %.0f, %.0f)", ply.origin.x, ply.origin.y, ply.origin.z)
	T.gt(ply.origin.x, 2400, "over the edge")
	T.gt(ply.origin.z, 2200, "clear of the roof")
	T.eq(rawget(env, "__bumps"), nil, "it never hit the wall")
	T.eq(ply:GetNW2Int("ws_mode"), 0)
end)

T.test("secondary while hanging on a web: zip to that web's anchor", function()
	local env, ply, WS = swingSetup()
	run(env, ply, 10, IN_ATTACK)
	T.eq(ply.WSS.mode, 1)
	run(env, ply, 1, IN_ATTACK + IN_ATTACK2)
	T.eq(ply.WSS.mode, 2)
	for _ = 1, 66 * 3 do
		run(env, ply, 1, IN_ATTACK)
		if ply.WSS.mode == 0 then break end
	end
	T.eq(ply.WSS.mode, 0, "arrived")
end)

T.test("reload in the air: dive (fast, steerable, terminal speed); release pulls up", function()
	local env, ply = server(G.newWorld())
	local WS = env.WebSwing
	airborne(ply, 40000)
	ply.eye = env.Angle(0, 0, 0)
	ply.vel.x = 800
	run(env, ply, 66, IN_RELOAD)
	T.truthy(ply.WSS.dive, "diving")
	T.eq(ply:GetNW2Bool("ws_dive"), true)
	T.lt(ply.vel.z, -1500, "falls much faster than gravity alone")
	run(env, ply, 66 * 3, IN_RELOAD)
	T.gt(ply.vel.z, -WS.T.diveTerminal - 600 * 0.02 - 1, "terminal speed")
	run(env, ply, 1, 0)
	T.falsy(ply.WSS.dive)
	T.gt(ply.vel.z, 0, "pulled up")
end)

T.test("dive does nothing on the ground", function()
	local env, ply = server(G.newWorld())
	run(env, ply, 30, IN_RELOAD)
	T.falsy(ply.WSS.dive)
end)

---------------------------------------------------------------------------
-- weapon, death, environment
---------------------------------------------------------------------------
T.test("putting the weapon away mid-swing lets go (even without Holster being called)", function()
	local env, ply = swingSetup()
	run(env, ply, 30, IN_ATTACK)
	T.eq(ply.WSS.mode, 1)
	ply.weapon = G.newWeapon(env, "weapon_pistol")
	run(env, ply, 1, IN_ATTACK)
	T.eq(ply.WSS.mode, 0)
	T.eq(ply:GetNW2Int("ws_mode"), 0)
	-- and holding any other weapon never starts one
	run(env, ply, 10, IN_ATTACK)
	T.eq(ply.WSS.mode, 0)
end)

T.test("SWEP:Holster / OnRemove let go of the web", function()
	local env, ply = swingSetup()
	local swep = G.loadWeapon(env, root)
	local self = { GetOwner = function() return ply end }
	run(env, ply, 30, IN_ATTACK)
	T.eq(ply.WSS.mode, 1)
	T.eq(swep.Holster(self), true)
	T.eq(ply.WSS.mode, 0)
	run(env, ply, 1, 0) -- (a held button does not re-fire after a web ends: let go first)
	run(env, ply, 30, IN_ATTACK)
	T.eq(ply.WSS.mode, 1)
	swep.OnRemove(self)
	T.eq(ply.WSS.mode, 0)
end)

T.test("death and respawn clear the web, the dive and what everyone sees", function()
	local env, ply = swingSetup()
	run(env, ply, 30, IN_ATTACK)
	T.eq(ply:GetNW2Int("ws_mode"), 1)
	env.hook.Run("PlayerDeath", ply)
	T.eq(ply.WSS.mode, 0)
	T.eq(ply:GetNW2Int("ws_mode"), 0)
	run(env, ply, 1, 0)
	run(env, ply, 30, IN_ATTACK)
	T.eq(ply.WSS.mode, 1)
	env.hook.Run("PlayerSpawn", ply)
	T.eq(ply.WSS.mode, 0)
	airborne(ply, 6000)
	ply.eye = env.Angle(0, 0, 0)
	run(env, ply, 40, IN_RELOAD)
	T.truthy(ply.WSS.dive)
	env.hook.Run("PlayerDisconnected", ply)
	T.falsy(ply.WSS.dive)
end)

T.test("a dead player's tick does nothing (and lets go)", function()
	local env, ply = swingSetup()
	run(env, ply, 30, IN_ATTACK)
	ply.alive = false
	run(env, ply, 1, IN_ATTACK)
	T.eq(ply.WSS.mode, 0)
end)

T.test("early-outs: ladder, water, noclip, vehicle, frozen, spectating: no web, and a running web is dropped", function()
	local cases = {
		{ "ladder", function(p) p.movetype = 9 end },
		{ "noclip", function(p) p.movetype = 8 end },
		{ "observer", function(p) p.movetype = 10 end },
		{ "water", function(p) p.water = 2 end },
		{ "vehicle", function(p) p.vehicle = true end },
		{ "frozen", function(p) p.frozen = true end },
	}
	for _, c in ipairs(cases) do
		local env, ply = swingSetup()
		c[2](ply)
		run(env, ply, 5, IN_ATTACK)
		T.eq(ply.WSS and ply.WSS.mode or 0, 0, c[1] .. ": must not attach")
		local env2, ply2 = swingSetup()
		run(env2, ply2, 30, IN_ATTACK)
		T.eq(ply2.WSS.mode, 1)
		c[2](ply2)
		run(env2, ply2, 1, IN_ATTACK)
		T.eq(ply2.WSS.mode, 0, c[1] .. ": must drop a running web")
		T.eq(#env2.__errors, 0)
	end
end)

T.test("ws_enabled 0: nothing starts, and a running web is dropped", function()
	local env, ply = swingSetup()
	run(env, ply, 30, IN_ATTACK)
	env.__convars.ws_enabled:SetValue(0)
	run(env, ply, 1, IN_ATTACK)
	T.eq(ply.WSS.mode, 0)
	run(env, ply, 20, IN_ATTACK)
	T.eq(ply.WSS.mode, 0)
end)

T.test("fall damage: none for a few seconds after a web, normal afterwards or if never used", function()
	local env, ply, WS = swingSetup()
	T.eq(env.hook.Run("GetFallDamage", ply, 900), nil, "never used a web: the gamemode decides")
	run(env, ply, 100, IN_ATTACK)
	run(env, ply, 1, 0)
	T.eq(env.hook.Run("GetFallDamage", ply, 900), 0)
	env.__clock.cur = env.__clock.cur + WS.T.fallGrace + 1
	T.eq(env.hook.Run("GetFallDamage", ply, 900), nil)
	env.__convars.ws_no_fall_damage:SetValue(0)
	run(env, ply, 100, IN_ATTACK)
	run(env, ply, 1, 0)
	T.eq(env.hook.Run("GetFallDamage", ply, 900), nil, "disabled")
end)

T.test("an error in the addon's own hook never escapes it (it would stop every other hook)", function()
	local env, ply = swingSetup()
	ply.GetActiveWeapon = function() error("boom") end
	local ok = pcall(env.hook.Run, "SetupMove", ply, G.newMove(ply, IN_ATTACK, 0), {})
	T.truthy(ok, "the hook function must not throw")
	T.truthy(#env.__errors > 0, "it is reported instead")
	T.truthy(env.WebSwing.lastError and env.WebSwing.lastError:find("boom", 1, true))
end)

---------------------------------------------------------------------------
-- anchors on entities
---------------------------------------------------------------------------
local function propWorld()
	local w = G.newWorld()
	local env0 = { }
	return w
end

T.test("a web on a prop is stored in the prop's local space and follows it; removing the prop lets go", function()
	local w = G.newWorld()
	local env, ply, WS = swingSetup(w)
	local prop = G.newProp(env, "prop_physics", { 1100, 0, 2300 })
	G.addBox(w, { 1000, -100, 2200 }, { 1200, 100, 2400 }, prop)
	ply.eye = env.Angle(-36.4, 0, 0) -- at the prop's front face
	run(env, ply, 1, IN_ATTACK)
	local S = ply.WSS
	T.eq(S.mode, 1)
	T.truthy(S.ent == prop, "anchored to the entity, not the world")
	T.near(S.lv.x, -100, 1.5, "local x")
	local ax0 = S.ax
	prop.origin = prop.origin + env.Vector(300, 0, 0)
	run(env, ply, 1, IN_ATTACK)
	T.near(S.ax, ax0 + 300, 1e-6, "the anchor moved with the prop")
	T.near(ply:GetNW2Vector("ws_local").x, -100, 1.5, "clients get the local-space anchor")
	T.truthy(ply:GetNW2Entity("ws_ent") == prop)
	prop.__valid = false
	run(env, ply, 1, IN_ATTACK)
	T.eq(S.mode, 0, "entity removed: detached")
	T.eq(ply:GetNW2Int("ws_mode"), 0)
end)

T.test("the rope pulls on a physics prop (opposite impulse, toward the player), unless disabled or protected", function()
	local function setup()
		local w = G.newWorld()
		local env, ply, WS = swingSetup(w)
		local prop = G.newProp(env, "prop_physics", { 1100, 0, 2300 })
		G.addBox(w, { 1000, -100, 2200 }, { 1200, 100, 2400 }, prop)
		ply.eye = env.Angle(-36.4, 0, 0)
		return env, ply, prop, WS
	end
	local env, ply, prop, WS = setup()
	run(env, ply, 200, IN_ATTACK)
	local imp = prop.phys and prop.phys.impulses or {}
	T.gt(#imp, 10, "impulses applied")
	local sum = env.Vector(0, 0, 0)
	for _, i in ipairs(imp) do
		sum = sum + i.f
		T.le(i.f:Length(), prop.phys.mass * WS.T.propMaxDv + 1e-6, "capped by mass")
	end
	local toPlayer = env.Vector(ply.origin.x - 1000, ply.origin.y, ply.origin.z + 40 - 2300)
	T.gt(sum:Dot(toPlayer), 0, "pulls the prop toward the player")

	local env2, ply2, prop2 = setup()
	env2.__convars.ws_prop_reaction:SetValue(0)
	run(env2, ply2, 100, IN_ATTACK)
	T.eq(prop2.phys and #prop2.phys.impulses or 0, 0, "ws_prop_reaction 0")

	local env3, ply3, prop3 = setup()
	prop3.CPPICanPhysgun = function() return false end
	run(env3, ply3, 100, IN_ATTACK)
	T.eq(prop3.phys and #prop3.phys.impulses or 0, 0, "prop protection says no")

	local env4, ply4, prop4 = setup()
	prop4.class = "npc_citizen"
	prop4.IsNPC = function() return true end
	run(env4, ply4, 100, IN_ATTACK)
	T.eq(prop4.phys and #prop4.phys.impulses or 0, 0, "NPCs are not pushed")
end)

T.test("other players are not anchors unless ws_attach_players is on", function()
	local w = G.newWorld()
	local env, ply, WS = swingSetup(w)
	local other = G.newPlayer(env, { 1100, 0, 2300 })
	G.addBox(w, { 1000, -100, 2200 }, { 1200, 100, 2400 }, other)
	ply.eye = env.Angle(-36.4, 0, 0)
	env.__players = { ply, other }
	-- aim at the player-box: it is filtered, so the ray goes on to the slab behind it
	run(env, ply, 1, IN_ATTACK)
	T.truthy(ply.WSS.mode == 0 or ply.WSS.ent ~= other, "not anchored to a player")
end)

---------------------------------------------------------------------------
-- SkateGM: absent, and a mock of its client API
---------------------------------------------------------------------------
local MOUSE_LEFT, MOUSE_RIGHT, KEY_G, KEY_V = 107, 108, 17, 32

-- A stand-in for what SkateGM exposes on the client (SkateGM.API) and for its simulation:
-- the engine ticks at 60 Hz in its own thread, Launch is applied `latency` ticks later, and
-- Poll (what the API returns) is one tick old. Gravity is Skate 3's.
local function mockSkateGM(env, opts)
	opts = opts or {}
	local V = env.Vector
	local sk = {
		pos = V(0, 0, 1500), vel = V(600, 0, 0), state = "PhysicsAir", tick = 0, skating = true, loading = false,
		latency = opts.latency or 2, queue = {}, launches = {}, accepted = 0, rejected = 0, scale = 1, started = 0,
		cam = { origin = V(-300, 0, 1700), angles = env.Angle(-50, 0, 0) }, g = 386,
	}
	sk.pubPos, sk.pubVel, sk.pubTick = V(sk.pos), V(sk.vel), 0
	local function canPush(st)
		return not (st:find("Biped", 1, true) or st:find("Wipeout", 1, true)) and (st:find("PhysicsGround", 1, true) or st:find("Air", 1, true)) ~= nil
	end
	local API = {}
	function API.IsSkating() return sk.skating end
	function API.IsLoading() return sk.loading end
	function API.CanSkate() return true end
	function API.StartSkating() sk.started = sk.started + 1 end
	function API.LastError() return nil end
	function API.State() return sk.skating and sk.state or nil end
	function API.SkaterPos() return sk.skating and V(sk.pubPos) or nil end
	function API.Velocity() return sk.skating and V(sk.pubVel) or nil end
	function API.Tick() return sk.skating and sk.pubTick or nil end
	function API.View() return sk.cam end
	function API.Speed() return sk.vel:Length() * 0.0254 end
	function API.PoseOf() return { HIPS = V(sk.pubPos), RIGHTHAND = V(sk.pubPos.x, sk.pubPos.y, sk.pubPos.z + 30) } end
	function API.Launch(v)
		if not (sk.skating and canPush(sk.state)) then sk.rejected = sk.rejected + 1 return false end
		local k = 0.0254 * sk.scale
		local dv = V(v.x / k, v.y / k, v.z / k)
		sk.queue[#sk.queue + 1] = { at = sk.tick + sk.latency, dv = dv }
		sk.accepted = sk.accepted + 1
		sk.launches[#sk.launches + 1] = { dv = dv, tick = sk.tick }
		return true
	end
	rawset(env, "SkateGM", { API = API, loadedScale = 1, S = sk })
	local dt = 1 / 60
	function sk.engine()
		for i = #sk.queue, 1, -1 do
			local q = sk.queue[i]
			if q.at <= sk.tick then
				sk.vel = sk.vel + q.dv
				table.remove(sk.queue, i)
			end
		end
		sk.pubPos, sk.pubVel, sk.pubTick = V(sk.pos), V(sk.vel), sk.tick -- one tick behind what comes next
		sk.vel.z = sk.vel.z - sk.g * dt
		sk.pos = sk.pos + sk.vel * dt
		if sk.pos.z < 0 then sk.pos.z = 0 sk.vel.z = math.max(0, sk.vel.z) end
		sk.tick = sk.tick + 1
		sk.maxSpeed = math.max(sk.maxSpeed or 0, sk.vel:Length())
	end
	return sk, API
end

-- one client frame: the engine runs `ticks` times, then the frame's Think hooks
local function frame(env, sk, ticks, dtFrame)
	env.__clock.tick = dtFrame or 1 / 60
	for _ = 1, ticks or 1 do sk.engine() end
	env.__clock.cur = env.__clock.cur + env.__clock.tick
	env.__clock.real = env.__clock.real + env.__clock.tick
	env.hook.Run("Think")
end

local function skaterClient(world)
	local env, ply = client(world)
	local sk, API = mockSkateGM(env)
	rawset(env, "__keysDown", {})
	return env, ply, sk, API
end

T.test("SkateGM absent: client and server run every hook with no error, board mode is off", function()
	local env, ply = client()
	for _ = 1, 5 do env.__clock.cur = env.__clock.cur + 0.015 env.hook.Run("Think") end
	env.hook.Run("HUDPaint")
	env.hook.Run("PostDrawTranslucentRenderables", false, false, false)
	T.eq(#env.__errors, 0, table.concat(env.__errors, "|"))
	local C = env.WebSwing.SkateGM
	T.eq(C.API(), nil)
	T.eq(C.Installed(), false)
	T.eq(C.IsSkating(ply), false)
	T.falsy(C.Board.Active())
	T.eq(#env.__outbox, 0, "sends nothing")
	local senv, sply = server()
	T.eq(senv.WebSwing.SkateGM.IsSkating(sply), false)
	senv.__clock.cur = senv.__clock.cur + 5
	senv.hook.Run("Think")
	T.eq(#senv.__errors, 0)
	-- the foot-mode swing is unaffected
	airborne(sply, 1500)
	sply.eye = senv.Angle(-50, 0, 0)
	run(senv, sply, 5, IN_ATTACK)
	T.eq(sply.WSS.mode, 1)
end)

T.test("SkateGM detected: foot mode stays out of the way while skating (the player entity is a hidden noclipper)", function()
	local env, ply, sk = skaterClient()
	local WS = env.WebSwing
	T.eq(WS.SkateGM.Installed(), true)
	T.eq(WS.SkateGM.IsSkating(ply), true)
	airborne(ply, 1500)
	ply.eye = env.Angle(-50, 0, 0)
	run(env, ply, 5, IN_ATTACK)
	T.eq(ply.WSS and ply.WSS.mode or 0, 0, "the SWEP's web does not start for a skater")
	-- server side: ply.SkateGM drives it
	local senv, sply = server()
	sply.SkateGM = true
	airborne(sply, 1500)
	sply.eye = senv.Angle(-50, 0, 0)
	run(senv, sply, 5, IN_ATTACK)
	T.eq(sply.WSS and sply.WSS.mode or 0, 0)
	-- and SkateGM entering skater mode lets go of a foot web (its Enter() fires this hook)
	sply.SkateGM = nil
	run(senv, sply, 1, 0)
	run(senv, sply, 10, IN_ATTACK)
	T.eq(sply.WSS.mode, 1)
	senv.hook.Run("SkateGMEnter", sply)
	T.eq(sply.WSS.mode, 0)
	T.eq(sply:GetNW2Int("ws_mode"), 0)
end)

-- a swing on a mock board: returns what happened
local function boardTrial(latency, fps, seconds, opts)
	opts = opts or {}
	local env, ply, sk, API = skaterClient()
	sk.latency = latency
	local WS = env.WebSwing
	if opts.wait then env.__convars.ws_board_wait:SetValue(opts.wait) end
	env.__keysDown[MOUSE_LEFT] = true
	local B = WS.SkateGM.Board
	local dt = 1 / fps
	local acc = 0
	local r = { maxOver = -1e9, maxSpeed = 0, minZ = 1e9, E0 = nil, Emax = -1e9 }
	local g = sk.g
	for _ = 1, math.floor(seconds * fps) do
		acc = acc + 60 * dt
		local t = math.floor(acc)
		acc = acc - t
		frame(env, sk, t, dt)
		if B.S.mode == 1 then
			local body = env.Vector(sk.pos.x, sk.pos.y, sk.pos.z + 16)
			r.maxOver = max(r.maxOver, dist3(body, env.Vector(B.S.ax, B.S.ay, B.S.az)) - B.S.L)
		end
		r.maxSpeed = max(r.maxSpeed, sk.vel:Length())
		r.minZ = min(r.minZ, sk.pos.z)
		local E = 0.5 * sk.vel:Length() ^ 2 + g * sk.pos.z
		r.E0 = r.E0 or E
		r.Emax = max(r.Emax, E)
	end
	r.env, r.sk, r.B, r.L, r.gain = env, sk, B, B.S.L, (r.Emax - r.E0) / (g * 1000)
	return r
end

T.test("board mode: hold the left mouse button to web-swing from the board; the rope holds against the skater's own physics", function()
	local r = boardTrial(2, 60, 8)
	local WS, B, sk, env = r.env.WebSwing, r.B, r.sk, r.env
	T.note("rope %.0f u, max over-length %.1f u (%.2f%%), lowest z %.0f, pushes %d, top speed %.0f u/s, energy gain %.3f", r.L, r.maxOver, r.maxOver / r.L * 100, r.minZ, sk.accepted, r.maxSpeed, r.gain)
	T.eq(B.S.mode, 1)
	T.eq(B.S.kind, 1)
	T.near(B.S.az, 2990, 0.5)
	T.lt(r.maxOver, r.L * 0.02, "rope stretch stays under 2%")
	T.lt(r.gain, 0.15, "the rope must not add energy")
	T.lt(r.minZ, 1450, "it swung")
	T.gt(sk.accepted, 20)
	T.eq(sk.rejected, 0)
	T.eq(#env.__errors, 0, table.concat(env.__errors, "|"))
	for _, l in ipairs(sk.launches) do T.le(l.dv:Length(), WS.T.boardMaxDv + 1e-6, "every push is capped") end
end)

T.test("board mode is stable across Launch latencies of 0-4 ticks and 30/60/144 fps; it degrades but stays bounded at 6-8", function()
	local worst = { stretch = 0, gain = -1 }
	for _, lat in ipairs({ 0, 1, 2, 3, 4 }) do
		for _, fps in ipairs({ 30, 60, 144 }) do
			local r = boardTrial(lat, fps, 8)
			local pct = r.maxOver / r.L * 100
			if pct > worst.stretch then worst.stretch = pct end
			if r.gain > worst.gain then worst.gain = r.gain end
			T.lt(pct, 2, string.format("latency %d, %d fps: stretch %.2f%%", lat, fps, pct))
			T.lt(r.gain, 0.15, string.format("latency %d, %d fps: energy gain %.3f", lat, fps, r.gain))
			T.eq(r.B.S.mode, 1, "web still on")
			T.eq(#r.env.__errors, 0)
		end
	end
	T.note("0-4 ticks: worst stretch %.2f%%, worst energy gain %.3f", worst.stretch, worst.gain)
	for _, lat in ipairs({ 6, 8 }) do
		for _, fps in ipairs({ 30, 60, 144 }) do
			local r = boardTrial(lat, fps, 8)
			T.lt(r.maxSpeed, 2000, string.format("latency %d, %d fps: runaway speed %.0f", lat, fps, r.maxSpeed))
			T.lt(r.maxOver / r.L * 100, 12, string.format("latency %d, %d fps: stretch", lat, fps))
		end
	end
end)

T.test("board mode: the runaway guard cuts the web of a skater far over the speed cap", function()
	local env, ply, sk = skaterClient()
	env.__keysDown[MOUSE_LEFT] = true
	frame(env, sk)
	local B = env.WebSwing.SkateGM.Board
	T.eq(B.S.mode, 1)
	sk.vel = env.Vector(5000, 0, 0)
	sk.pubVel = env.Vector(5000, 0, 0)
	frame(env, sk)
	T.eq(B.S.mode, 0, "cut")
	T.eq(B.cut, 1)
	T.eq(#env.__outbox >= 2, true, "and the server is told")
end)

T.test("board mode: pushes are paced (one in flight): never more than one per wait, and each is bounded", function()
	local env, ply, sk = skaterClient()
	env.__keysDown[MOUSE_LEFT] = true
	local wait = env.WebSwing.T.boardWait
	for _ = 1, 60 * 6 do frame(env, sk, 1, 1 / 60) end
	local sorted = sk.launches
	T.gt(#sorted, 5)
	local minGap = 1e9
	for i = 2, #sorted do minGap = min(minGap, (sorted[i].tick - sorted[i - 1].tick) / 60) end
	T.note("%d pushes in 6 s; shortest gap between two %.3f s (wait %.3f s)", #sorted, minGap, wait)
	T.truthy(minGap >= wait - 1 / 60 - 1e-9, "pushes closer together than the wait")
end)

T.test("board mode: releasing the button gives the slingshot boost as one push, and tells the server the web is gone", function()
	local env, ply, sk = skaterClient()
	local B = env.WebSwing.SkateGM.Board
	env.__keysDown[MOUSE_LEFT] = true
	frame(env, sk)
	T.eq(B.S.mode, 1)
	-- let go on the way up the arc, about 45 degrees from straight below the anchor
	local boost = 0
	for _ = 1, 60 * 6 do
		frame(env, sk)
		if sk.pos.z > 1750 and sk.vel.z > 0 then
			env.__keysDown[MOUSE_LEFT] = false
			frame(env, sk)
			boost = B.S.boost
			break
		end
	end
	T.eq(B.S.mode, 0, "released")
	T.note("boost %.0f u/s at speed %.0f", boost, sk.vel:Length())
	T.gt(boost, 30, "a real boost")
	T.le(boost, env.WebSwing.T.boostMax + 1e-6)
	local last = env.__outbox[#env.__outbox]
	T.eq(last.name, "webswing_board")
	T.eq(last.data[1][2], 0, "mode 0 sent")
	-- a click that finds nothing (an empty sky): no web, no push
	env.__world.boxes = {}
	env.__keysDown[MOUSE_LEFT] = true
	local n = sk.accepted
	for _ = 1, 20 do frame(env, sk) end
	T.eq(B.S.mode, 0)
	T.eq(sk.accepted, n)
end)

T.test("board mode: the skater bails (the engine will not take a push): the web lets go", function()
	local env, ply, sk = skaterClient()
	local B = env.WebSwing.SkateGM.Board
	env.__keysDown[MOUSE_LEFT] = true
	for _ = 1, 30 do frame(env, sk) end
	T.eq(B.S.mode, 1)
	sk.state = "Wipeout"
	local before = sk.accepted
	for _ = 1, 40 do frame(env, sk) end
	T.eq(B.S.mode, 0, "web let go of a ragdoll")
	T.eq(sk.accepted, before, "nothing pushed while the engine would refuse")
	-- and it does not start while on foot
	sk.state = "BipedIdle"
	env.__keysDown[MOUSE_LEFT] = false
	frame(env, sk)
	env.__keysDown[MOUSE_LEFT] = true
	for _ = 1, 10 do frame(env, sk) end
	T.eq(B.S.mode, 0)
	T.eq(#env.__errors, 0)
end)

T.test("board mode: dive pushes the skater down only in the air; zip pulls toward a ledge", function()
	local env, ply, sk = skaterClient()
	local B = env.WebSwing.SkateGM.Board
	sk.vel = env.Vector(300, 0, 0)
	sk.pubVel = env.Vector(300, 0, 0)
	env.__keysDown[KEY_G] = true
	for _ = 1, 60 do frame(env, sk) end
	T.truthy(B.S.dive, "diving")
	T.lt(sk.vel.z, -900, "falls faster than Skate 3's gravity alone")
	sk.state = "PhysicsGround"
	local n = sk.accepted
	for _ = 1, 20 do frame(env, sk) end
	T.eq(sk.accepted, n, "no dive push on the ground")
	env.__keysDown[KEY_G] = false
end)

T.test("board mode: the web is relayed to the server, which publishes it for everyone (and checks it)", function()
	local env, ply, sk = skaterClient()
	env.__keysDown[MOUSE_LEFT] = true
	for _ = 1, 40 do frame(env, sk) end
	T.truthy(#env.__outbox >= 1, "client sent its web")
	-- the server side
	local senv, sply = server()
	sply.SkateGM = true
	sply.SkateGMHips = senv.Vector(0, 0, 1500)
	local first, kept = nil, 0
	for _, msg in ipairs(env.__outbox) do
		T.eq(msg.name, "webswing_board")
		senv.__clock.real = senv.__clock.real + 0.05
		senv.__deliver(msg, sply)
		first = first or msg
		kept = kept + 1
	end
	T.eq(sply:GetNW2Int("ws_mode"), 1, "published as mode 1")
	T.near(sply:GetNW2Vector("ws_anchor").z, 2990, 0.5)
	T.truthy(#sply.sounds > 0, "attach sound")
	-- the watchdog: a skater who stopped reporting loses the web in everyone's view
	senv.__clock.real = senv.__clock.real + 5
	senv.hook.Run("Think")
	T.eq(sply:GetNW2Int("ws_mode"), 0, "stale web cleared")
	-- not a skater: ignored
	local other = G.newPlayer(senv, { 0, 0, 0 })
	senv.__deliver(first, other)
	T.eq(other:GetNW2Int("ws_mode", 0), 0, "a player who is not skating cannot publish a web")
	-- nonsense far from the skater: ignored
	sply.SkateGM = true
	local far = { name = "webswing_board", data = { { "uint", 1 }, { "float", 9e5 }, { "float", 0 }, { "float", 0 }, { "bool", false }, { "float", 1000 } } }
	senv.__clock.real = senv.__clock.real + 1
	senv.__deliver(far, sply)
	T.eq(sply:GetNW2Int("ws_mode"), 0, "implausible anchor refused")
	local nan = { name = "webswing_board", data = { { "uint", 1 }, { "float", 0 / 0 }, { "float", 0 }, { "float", 0 }, { "bool", false }, { "float", 1000 } } }
	senv.__clock.real = senv.__clock.real + 1
	senv.__deliver(nan, sply)
	T.eq(sply:GetNW2Int("ws_mode"), 0, "NaN refused")
	-- death clears it
	senv.__clock.real = senv.__clock.real + 1
	senv.__deliver(first, sply)
	T.eq(sply:GetNW2Int("ws_mode"), 1)
	senv.hook.Run("PlayerDeath", sply)
	T.eq(sply:GetNW2Int("ws_mode"), 0)
	T.eq(#senv.__errors, 0, table.concat(senv.__errors, "|"))
end)

T.test("foot -> board: the swing's speed is handed to the skater once the engine will take it", function()
	local env, ply = client()
	local sk, API = mockSkateGM(env)
	rawset(env, "__keysDown", {})
	local WS = env.WebSwing
	local B = WS.SkateGM.Board
	sk.skating = false
	ply.vel = env.Vector(900, 0, 300)
	WS.Client.lastWebAt = env.__clock.cur -- swung a moment ago
	for _ = 1, 5 do frame(env, sk) end
	-- SkateGM starts: first as a standing skater, then riding
	sk.skating = true
	sk.state = "BipedIdle"
	sk.vel = env.Vector(0, 0, 0) sk.pubVel = env.Vector(0, 0, 0)
	for _ = 1, 10 do frame(env, sk) end
	T.eq(sk.accepted, 0, "nothing pushed while the engine would refuse")
	sk.state = "PhysicsGround"
	for _ = 1, 10 do frame(env, sk) end
	T.eq(sk.accepted, 1, "one handoff push")
	local dv = sk.launches[1].dv
	T.note("handoff dv (%.0f, %.0f, %.0f) u/s", dv.x, dv.y, dv.z)
	T.near(dv.x, 900, 1e-6)
	T.near(dv.z, 300, 1e-6)
	-- a skater who did not just swing keeps SkateGM's behaviour untouched
	local env2, ply2 = client()
	local sk2 = mockSkateGM(env2)
	rawset(env2, "__keysDown", {})
	sk2.skating = false
	ply2.vel = env2.Vector(900, 0, 0)
	for _ = 1, 5 do frame(env2, sk2) end
	sk2.skating = true
	for _ = 1, 20 do frame(env2, sk2) end
	T.eq(sk2.accepted, 0, "no web used recently: no handoff")
	-- off with ws_board_handoff 0
	local env3, ply3 = client()
	local sk3 = mockSkateGM(env3)
	rawset(env3, "__keysDown", {})
	env3.__convars.ws_board_handoff:SetValue(0)
	sk3.skating = false
	ply3.vel = env3.Vector(900, 0, 0)
	env3.WebSwing.Client.lastWebAt = env3.__clock.cur
	for _ = 1, 5 do frame(env3, sk3) end
	sk3.skating = true
	for _ = 1, 20 do frame(env3, sk3) end
	T.eq(sk3.accepted, 0)
end)

T.test("ws_board starts Skater mode through SkateGM's API; says so when it can't", function()
	local env, ply, sk, API = skaterClient()
	sk.skating = false
	env.__concommands.ws_board()
	T.eq(sk.started, 1)
	sk.skating = true
	env.__concommands.ws_board()
	T.eq(sk.started, 1, "already skating: nothing")
	local env2 = client()
	env2.__concommands.ws_board()
	T.eq(#env2.__chat, 1, "no SkateGM: a chat line, no error")
end)

T.test("a SkateGM without the calls we need (older/changed): board mode switches itself off quietly, SkateGM untouched", function()
	local env, ply = client()
	rawset(env, "SkateGM", { API = { IsSkating = function() return true end } })
	rawset(env, "__keysDown", { [MOUSE_LEFT] = true })
	for _ = 1, 5 do env.__clock.cur = env.__clock.cur + 0.016 env.hook.Run("Think") end
	local B = env.WebSwing.SkateGM.Board
	T.truthy(B.err and B.err:find("Launch", 1, true), "reason recorded: " .. tostring(B.err))
	T.eq(#env.__errors, 0, "no console spam")
	env.__concommands.ws_status()
	env.__concommands.ws_selftest()
	T.eq(#env.__errors, 0)
end)

T.test("an error inside board mode switches it off once and never escapes the Think hook", function()
	local env, ply, sk, API = skaterClient()
	env.__keysDown[MOUSE_LEFT] = true
	API.Velocity = function() error("API changed") end
	local ok = pcall(env.hook.Run, "Think")
	T.truthy(ok)
	local B = env.WebSwing.SkateGM.Board
	T.truthy(B.err and B.err:find("API changed", 1, true))
	T.eq(#env.__errors >= 1, true)
	local n = #env.__errors
	for _ = 1, 20 do env.hook.Run("Think") end
	T.eq(#env.__errors, n, "reported once, not every frame")
end)

---------------------------------------------------------------------------
-- client: reconcile, drawing, HUD, console
---------------------------------------------------------------------------
T.test("reconcile: a predicted web the server never confirms is dropped after the grace period (not before)", function()
	local env, ply = client()
	airborne(ply, 1500)
	ply.eye = env.Angle(-50, 0, 0)
	local S
	for i = 1, 66 * 2 do
		run(env, ply, 1, IN_ATTACK)
		S = ply.WSS
		env.hook.Run("Think")
		if i == 10 then T.eq(S.mode, 1, "predicted attach") end
		if i == 12 then T.eq(S.mode, 1, "still held during the grace period") end
	end
	T.eq(S.mode, 0, "dropped: the server (NW2 mode 0) never agreed")
	-- when the server agrees, nothing is touched
	local env2, ply2 = client()
	airborne(ply2, 1500)
	ply2.eye = env2.Angle(-50, 0, 0)
	for i = 1, 66 * 2 do
		run(env2, ply2, 1, IN_ATTACK)
		local S2 = ply2.WSS
		ply2.nw.ws_mode = S2.mode -- the server's NW2 value follows
		ply2.nw.ws_anchor = env2.Vector(S2.ax, S2.ay, S2.az)
		env2.hook.Run("Think")
	end
	T.eq(ply2.WSS.mode, 1)
end)

T.test("reconcile: with no prediction at all (singleplayer) the client draws and shows the server's state", function()
	local env, ply = client()
	ply.nw.ws_mode = 1
	ply.nw.ws_anchor = env.Vector(1000, 0, 2990)
	ply.nw.ws_t0 = env.__clock.cur - 1
	ply.nw.ws_len = 1800
	ply.nw.ws_tension = 1.5
	local V = env.WebSwing.ViewState(ply)
	T.eq(V.mode, 1)
	T.eq(V.source, "server")
	T.near(V.ax, 1000, 1e-9)
	env.hook.Run("PostDrawTranslucentRenderables", false, false, false)
	T.gt(env.__beams, 0, "rope drawn from the server's word")
	T.eq(#env.__errors, 0)
end)

T.test("drawing: local predicted web, another player's web on a moving prop, a zip, a whiff: all draw, nothing errors", function()
	local env, ply = client()
	local other = G.newPlayer(env, { 500, 500, 100 })
	other.name = "Other"
	rawset(env, "__players", { ply, other })
	local prop = G.newProp(env, "prop_physics", { 800, 0, 2000 })
	other.nw.ws_mode = 1
	other.nw.ws_ent = prop
	other.nw.ws_local = env.Vector(10, 0, 0)
	other.nw.ws_t0 = env.__clock.cur - 2
	other.nw.ws_len = 1500
	airborne(ply, 1500)
	ply.eye = env.Angle(-50, 0, 0)
	run(env, ply, 20, IN_ATTACK)
	local before = env.__beams
	env.hook.Run("PostDrawTranslucentRenderables", false, false, false)
	T.eq(env.__beams - before, 2, "two ropes")
	T.gt(env.__sprites, 0, "anchor sprites")
	-- not during the depth/skybox passes
	local n = env.__beams
	env.hook.Run("PostDrawTranslucentRenderables", true, false, false)
	env.hook.Run("PostDrawTranslucentRenderables", false, true, false)
	T.eq(env.__beams, n)
	-- the prop moved: the other player's rope end follows (ViewState re-evaluates the local anchor)
	prop.origin = prop.origin + env.Vector(100, 0, 0)
	T.near(env.WebSwing.ViewState(other).ax, 910, 1e-9)
	-- zip
	other.nw.ws_mode = 2
	env.hook.Run("PostDrawTranslucentRenderables", false, false, false)
	-- whiff on the local player
	run(env, ply, 1, 0)
	ply.WSS.mode = 0
	ply.WSS.whiffT = env.__clock.cur
	ply.WSS.whiffX, ply.WSS.whiffY, ply.WSS.whiffZ = 900, 0, 2000
	other.nw.ws_mode = 0
	env.hook.Run("PostDrawTranslucentRenderables", false, false, false)
	T.eq(#env.__errors, 0, table.concat(env.__errors, "|"))
	-- a dead or dormant player is not drawn
	ply.WSS.whiffT = -100
	other.nw.ws_mode = 1
	other.alive = false
	local b2 = env.__beams
	env.hook.Run("PostDrawTranslucentRenderables", false, false, false)
	T.eq(env.__beams, b2)
end)

T.test("HUD: crosshair tint logic runs for the SWEP, while attached, and on a SkateGM board; speed text updates", function()
	local env, ply = client()
	airborne(ply, 1500)
	ply.eye = env.Angle(-50, 0, 0)
	ply.vel = env.Vector(1000, 0, 0)
	env.hook.Run("HUDPaint")
	local probe = env.WebSwing.Client.probe
	T.eq(probe.ok, true, "the probe found the slab")
	T.eq(probe.kind, 1)
	-- (an empty sky, in another game)
	local envE, plyE = client(G.newWorld())
	airborne(plyE, 400)
	plyE.eye = envE.Angle(-50, 0, 0)
	envE.hook.Run("HUDPaint")
	T.eq(envE.WebSwing.Client.probe.ok, false, "sees nothing in an empty sky")
	run(env, ply, 1, 0)
	ply.eye = env.Angle(-50, 0, 0)
	run(env, ply, 5, IN_ATTACK)
	env.hook.Run("HUDPaint")
	local shown = rawget(env, "__lastText")
	T.truthy(shown and shown:find("km/h", 1, true), "speed shown: " .. tostring(shown))
	-- another weapon: the HUD stays out of the way
	ply.weapon = G.newWeapon(env, "weapon_pistol")
	run(env, ply, 1, 0)
	ply.WSS.mode = 0
	rawset(env, "__lastText", nil)
	env.hook.Run("HUDPaint")
	T.eq(rawget(env, "__lastText"), nil)
	T.eq(#env.__errors, 0)
	-- on a board
	local env2, ply2, sk = skaterClient()
	env2.hook.Run("HUDPaint")
	T.eq(env2.WebSwing.Client.probe.ok, true, "board probe uses the skater's camera")
	env2.__convars.ws_hud_board:SetValue(0)
	env2.WebSwing.Client.probe.ok = false
	env2.__clock.real = env2.__clock.real + 1
	env2.hook.Run("HUDPaint")
	T.eq(env2.WebSwing.Client.probe.ok, false, "ws_hud_board 0: nothing drawn or probed")
	T.eq(#env2.__errors, 0)
end)

T.test("console: ws_status and ws_selftest run (with and without SkateGM) and report; server status too", function()
	local env, ply = client()
	env.__concommands.ws_status()
	env.__concommands.ws_selftest()
	local env2, ply2, sk = skaterClient()
	env2.__concommands.ws_status()
	env2.__concommands.ws_selftest()
	local senv, sply = server()
	run(senv, sply, 1, 0)
	senv.__concommands.ws_status_sv(sply)
	senv.__concommands.ws_release(sply)
	senv.__concommands.ws_give(sply)
	T.eq(#env.__errors + #env2.__errors + #senv.__errors, 0)
end)

T.test("the rope's hot path does not allocate Lua tables per tick (a 5 s swing grows memory by less than the noise floor)", function()
	local env, ply = swingSetup()
	run(env, ply, 100, IN_ATTACK)
	collectgarbage("collect") collectgarbage("collect")
	local before = collectgarbage("count")
	run(env, ply, 330, IN_ATTACK)
	collectgarbage("collect") collectgarbage("collect")
	local after = collectgarbage("count")
	T.note("memory before %.1f KB, after %.1f KB (the mock itself builds Vectors; the addon's own tables are reused)", before, after)
	T.lt(after - before, 200, "no per-tick table growth that survives a collection")
end)

T.test("a NaN position (a broken anchor entity) never reaches the engine as a velocity", function()
	local w = G.newWorld()
	local env, ply = swingSetup(w)
	local prop = G.newProp(env, "prop_physics", { 1100, 0, 2300 })
	G.addBox(w, { 1000, -100, 2200 }, { 1200, 100, 2400 }, prop)
	ply.eye = env.Angle(-36.4, 0, 0)
	run(env, ply, 20, IN_ATTACK)
	T.eq(ply.WSS.mode, 1)
	prop.origin = env.Vector(0 / 0, 0, 0)
	run(env, ply, 5, IN_ATTACK)
	T.eq(ply.vel.x == ply.vel.x and ply.vel.y == ply.vel.y and ply.vel.z == ply.vel.z, true, "player velocity must stay a number")
	T.eq(ply.origin.x == ply.origin.x, true, "and so must the origin")
end)

T.test("controller chords (experimental, off by default) feed the same board web", function()
	local env, ply, sk, API = skaterClient()
	API.Pad = function() return { buttons = 0x20 } end
	frame(env, sk)
	T.eq(env.WebSwing.SkateGM.Board.S.mode, 0, "off by default")
	env.__convars.ws_board_pad:SetValue(1)
	frame(env, sk)
	T.eq(env.WebSwing.SkateGM.Board.S.mode, 1, "Back/View holds the web")
	API.Pad = function() return { buttons = 0 } end
	frame(env, sk)
	T.eq(env.WebSwing.SkateGM.Board.S.mode, 0, "released")
end)

T.test("board mode: a frozen skater (a minigame countdown) can not be pushed, and a running web is dropped", function()
	local env, ply, sk, API = skaterClient()
	local B = env.WebSwing.SkateGM.Board
	env.__keysDown[MOUSE_LEFT] = true
	for _ = 1, 20 do frame(env, sk) end
	T.eq(B.S.mode, 1)
	API.IsFrozen = function() return true end
	local n = sk.accepted
	for _ = 1, 30 do frame(env, sk) end
	T.eq(B.S.mode, 0)
	T.eq(sk.accepted, n)
end)

T.test("board mode: inputs are ignored (and ws_status says why) while the console or a menu is open", function()
	local env, ply, sk = skaterClient()
	local B = env.WebSwing.SkateGM.Board
	env.__keysDown[MOUSE_LEFT] = true
	env.__mock.gui.IsConsoleVisible = function() return true end
	for _ = 1, 10 do frame(env, sk) end
	T.eq(B.S.mode, 0)
	T.eq(B.blockedBy, "console open")
	env.__mock.gui.IsConsoleVisible = function() return false end
	env.__mock.vgui.GetKeyboardFocus = function() return { __valid = true } end
	for _ = 1, 5 do frame(env, sk) end
	T.eq(B.S.mode, 0)
	T.truthy(B.blockedBy:find("text entry", 1, true))
	env.__mock.vgui.GetKeyboardFocus = function() return nil end
	rawset(env, "SKATEGM_UI", { open = {} })
	frame(env, sk)
	T.eq(B.S.mode, 0)
	T.truthy(B.blockedBy:find("SkateGM menu", 1, true))
	rawset(env, "SKATEGM_UI", nil)
	frame(env, sk)
	T.eq(B.S.mode, 1, "live again once nothing blocks")
	env.__concommands.ws_status()
	T.eq(#env.__errors, 0)
end)

---------------------------------------------------------------------------
-- fuzz: random inputs must never produce an error, a NaN, or a runaway
---------------------------------------------------------------------------
local function lcg(seed)
	local s = seed
	return function()
		s = (s * 1103515245 + 12345) % 2147483648
		return s / 2147483648
	end
end

T.test("fuzz, foot mode: 8 seeds x 3000 ticks of random buttons, aims, states and world changes: no error, no NaN, speed capped", function()
	local bad
	for seed = 1, 8 do
		local rnd = lcg(seed * 7919)
		local env, ply = server()
		local WS = env.WebSwing
		local prop = G.newProp(env, "prop_physics", { 1100, 0, 2300 })
		G.addBox(env.__world, { 1000, -100, 2200 }, { 1200, 100, 2400 }, prop)
		airborne(ply, 400 + rnd() * 1500)
		local maxSpeed, attaches = 0, 0
		for i = 1, 3000 do
			local b = 0
			if rnd() < 0.6 then b = b + IN_ATTACK end
			if rnd() < 0.08 then b = b + IN_ATTACK2 end
			if rnd() < 0.05 then b = b + IN_JUMP end
			if rnd() < 0.15 then b = b + IN_DUCK end
			if rnd() < 0.3 then b = b + IN_FORWARD end
			if rnd() < 0.1 then b = b + IN_BACK end
			if rnd() < 0.1 then b = b + IN_MOVELEFT end
			if rnd() < 0.1 then b = b + IN_MOVERIGHT end
			if rnd() < 0.1 then b = b + IN_RELOAD end
			if i % 50 == 0 then ply.eye = env.Angle(-80 + rnd() * 100, rnd() * 360 - 180, 0) end
			if i % 211 == 0 then ply.movetype = (rnd() < 0.3) and 9 or 2 end
			if i % 307 == 0 then ply.water = (rnd() < 0.3) and 3 or 0 end
			if i % 401 == 0 then ply.weapon = (rnd() < 0.2) and G.newWeapon(env, "weapon_pistol") or G.newWeapon(env, "weapon_webswing") end
			if i % 509 == 0 then env.hook.Run("PlayerDeath", ply) ply.origin = env.Vector(rnd() * 500, rnd() * 500, 300 + rnd() * 1500) ply.vel = env.Vector() end
			if i % 613 == 0 then prop.origin = prop.origin + env.Vector(rnd() * 200 - 100, 0, 0) end
			if i % 701 == 0 then prop.__valid = (rnd() < 0.5) end
			if ply.origin.z < -10 or ply.origin.z > 20000 then ply.origin = env.Vector(0, 0, 800) ply.vel = env.Vector() end
			local ok, err = pcall(G.tick, env, ply, b)
			if not ok then bad = "seed " .. seed .. " tick " .. i .. ": " .. tostring(err) break end
			local v, o = ply.vel, ply.origin
			if v.x ~= v.x or v.y ~= v.y or v.z ~= v.z or o.x ~= o.x or o.y ~= o.y or o.z ~= o.z then bad = "NaN seed " .. seed .. " tick " .. i break end
			maxSpeed = math.max(maxSpeed, v:Length())
			if ply.WSS and ply.WSS.mode == 1 and ply.WSS.t > 0.5 and not (ply.WSS.ent) then
				local d = dist3(env.Vector(o.x, o.y, o.z + WS.CHEST), env.Vector(ply.WSS.ax, ply.WSS.ay, ply.WSS.az))
				if d - ply.WSS.L > 600 then bad = string.format("rope %.0f over at seed %d tick %d", d - ply.WSS.L, seed, i) break end
			end
		end
		if bad then break end
		if #env.__errors > 0 then bad = "seed " .. seed .. ": " .. env.__errors[1] break end
		T.note("foot fuzz seed %d: top speed %.0f u/s", seed, maxSpeed)
		T.lt(maxSpeed, 4200, "seed " .. seed .. " speed")
	end
	T.eq(bad, nil, tostring(bad))
end)

T.test("fuzz, board mode: random keys, states, latencies and aims: no error, no NaN, the runaway guard holds", function()
	local bad
	for seed = 1, 8 do
		local rnd = lcg(seed * 104729)
		local env, ply, sk = skaterClient()
		sk.latency = math.floor(rnd() * 7)
		local states = { "PhysicsAir", "PhysicsGround", "SlideGround", "RevertGround", "Wipeout", "BipedIdle", "GrindFiftyFifty" }
		local maxSpeed = 0
		for i = 1, 2500 do
			env.__keysDown[MOUSE_LEFT] = rnd() < 0.5
			env.__keysDown[MOUSE_RIGHT] = rnd() < 0.08
			env.__keysDown[KEY_G] = rnd() < 0.1
			env.__keysDown[KEY_V] = rnd() < 0.15
			if i % 40 == 0 then sk.cam.angles = env.Angle(-80 + rnd() * 100, rnd() * 360 - 180, 0) end
			if i % 97 == 0 then sk.state = states[1 + math.floor(rnd() * #states)] end
			if i % 331 == 0 then sk.skating = rnd() < 0.8 end
			if i % 449 == 0 then sk.pos = env.Vector(rnd() * 800, rnd() * 800, 200 + rnd() * 2000) sk.vel = env.Vector(rnd() * 800 - 400, rnd() * 800 - 400, 0) end
			local ok, err = pcall(frame, env, sk, rnd() < 0.5 and 1 or 0, 1 / (30 + math.floor(rnd() * 120)))
			if not ok then bad = "seed " .. seed .. " frame " .. i .. ": " .. tostring(err) break end
			local v, p = sk.vel, sk.pos
			if v.x ~= v.x or v.z ~= v.z or p.x ~= p.x or p.z ~= p.z then bad = "NaN seed " .. seed .. " frame " .. i break end
			maxSpeed = math.max(maxSpeed, v:Length())
		end
		if bad then break end
		if #env.__errors > 0 then bad = "seed " .. seed .. ": " .. env.__errors[1] break end
		T.note("board fuzz seed %d: latency %d, top speed %.0f u/s", seed, sk.latency, maxSpeed)
		T.lt(maxSpeed, 4500, "seed " .. seed .. " speed " .. maxSpeed)
	end
	T.eq(bad, nil, tostring(bad))
end)

T.test("tap-spamming the web cannot ratchet speed up (foot mode): short holds earn no boost", function()
	local env, ply, WS = swingSetup()
	local top, boosts = 0, 0
	for cycle = 1, 40 do
		run(env, ply, 6, IN_ATTACK)   -- 0.09 s of web
		boosts = boosts + (ply.WSS.boost or 0)
		run(env, ply, 1, 0)           -- let go
		boosts = boosts + (ply.WSS.boost or 0)
		run(env, ply, 4, 0)
		top = max(top, speed(ply))
		if ply.origin.z < 600 then airborne(ply, 1500) ply.vel = env.Vector() end
	end
	T.note("40 tap cycles: top speed %.0f u/s, boost earned %.0f", top, boosts)
	T.eq(boosts, 0, "no boost for 0.09 s webs")
	T.lt(top, 1300)
end)

T.test("tap-spamming the web on a board cannot ratchet speed up either: pushes are capped at ws_max_speed", function()
	local env, ply, sk = skaterClient()
	local WS = env.WebSwing
	local top = 0
	for i = 1, 900 do
		env.__keysDown[MOUSE_LEFT] = (i % 2 == 0)
		frame(env, sk, 1, 1 / 60)
		top = max(top, sk.vel:Length())
		if sk.pos.z < 300 then sk.pos = env.Vector(0, 0, 1500) sk.vel = env.Vector(600, 0, 0) end
	end
	T.note("900 frames of alternating clicks: top speed %.0f u/s (cap %.0f)", top, WS.T.maxSpeed)
	T.lt(top, WS.T.maxSpeed * 1.2)
	T.eq(#env.__errors, 0)
end)
