-- client/survival.lua : the player's side of survival. Reports the position (player_state, the camera focus in colony view) and the damage the GAME dealt to the player that the server did
-- not already account for (a fall, a bullet, an explosion, a fire: onClientPlayerDamage), and applies the host's survival body to the controls (sprint lock, limp walk). The numbers
-- (hunger, thirst, bleeding, infection) and the player's health live in shared/survival.lua on the server, which also sets the ped's health (server/world.lua); zombie bites are scripted
-- damage on the server and never reach this handler. In colony view the player ped is only a camera anchor, so damage is cancelled there.
-- Written here (the FiveM adapter's client/survival.lua on MTA events). Nothing borrowed.
local ctx = require("client.ctx")

local S = { last_pos = nil, last_report = 0, fx = nil, stats = { damage = 0, reports = 0 } }

-- SA weapon / damage-type ids that onClientPlayerDamage reports: 54 fall, 53 drowning, 37 flamethrower, 51 explosion, 16 grenade, 18 molotov, 63 vehicle, 4 knife, 8 katana
local KIND_BY_WEAPON = { [54] = "fall", [37] = "fire", [18] = "fire", [51] = "explosion", [16] = "explosion", [4] = "cut", [8] = "cut", [9] = "cut" }
local function damage_kind(weapon)
	if KIND_BY_WEAPON[weapon] then return KIND_BY_WEAPON[weapon] end
	if weapon and weapon >= 22 and weapon <= 38 then return "bullet" end
	return "blunt"
end

function S.on_damage(attacker, weapon, bodypart, loss)
	if source ~= localPlayer then return end
	if ctx.colony_mode then cancelEvent(); return end
	-- a zombie's visible fist swing (client/driver.lua) must not hurt twice: its damage is scripted on the server and reaches the sim as player_damage
	if isElement(attacker) and getElementData(attacker, "ob") == "zombie" then cancelEvent(); return end
	if type(loss) == "number" and loss > 0 then
		S.stats.damage = S.stats.damage + 1
		ctx.send({ type = "player_damage", amount = loss, kind = damage_kind(weapon) })
	end
end

function S.apply_fx(fx)
	if type(fx) ~= "table" then return end
	S.fx = fx
	toggleControl("sprint", fx.sprint ~= false)
	setPedWalkingStyle(localPlayer, fx.limp and ctx.config.limp_walk or 0)
end

-- position in SIM space (the camera focus in colony view: camera.lua keeps ctx.player_sim current)
function S.step()
	local now = getTickCount()
	local sx, sy
	if ctx.colony_mode then
		sx, sy = ctx.player_sim.x, ctx.player_sim.y
	else
		local x, y = getElementPosition(localPlayer)
		sx, sy = ctx.to_sim(x, y)
		ctx.player_sim.x, ctx.player_sim.y = sx, sy
	end
	local moved = S.last_pos and math.sqrt((sx - S.last_pos.x) ^ 2 + (sy - S.last_pos.y) ^ 2) or 1e9
	if moved > 20.0 or now - S.last_report >= 1000 then
		S.last_pos, S.last_report = { x = sx, y = sy }, now
		S.stats.reports = S.stats.reports + 1
		ctx.send({ type = "player_state", pos = { x = sx, y = sy, z = 0.0 }, moving = (moved > 0.5 and moved < 1e8) })
	end
end

function S.cleanup()
	toggleControl("sprint", true)
	setPedWalkingStyle(localPlayer, 0)
	S.fx = nil
end

function S.start()
	addEventHandler("onClientPlayerDamage", root, S.on_damage)
	ctx.loop("survival", 200, S.step)
end

ctx.on_cleanup("survival", S.cleanup)
return S
