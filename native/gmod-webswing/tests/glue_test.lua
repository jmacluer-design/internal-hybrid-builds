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
	G.addBox(w, { -6000, -4000, 2990 }, { 6000, 4000, 3010 })          -- slab: underside at z=3000
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
