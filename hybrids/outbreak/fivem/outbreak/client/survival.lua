-- client/survival.lua : the player's side of survival. Reports position (player_state, from the camera focus in colony view), game damage the zombies module
-- did not already report (fall / bullet / explosion -> player_damage), death (ped_died player); applies the host's survival body back onto the ped
-- (health, sprint lock, limp) and respawns at the base after a death. The numbers (hunger, thirst, bleeding, infection) live in shared/survival.lua on the server.
local ctx = require("client.ctx")
local P = require("shared.protocol")

local S = { expected = nil, dead = false, died_at = 0, last_pos = nil, last_report = 0, fx = nil, stats = { damage = 0, deaths = 0, respawns = 0, reports = 0 } }

function S.apply_fx(fx)
	if type(fx) ~= "table" then return end
	S.fx = fx
	local ped = PlayerPedId()
	if not DoesEntityExist(ped) then return end
	S.expected = 100 + math.floor((fx.health or 1.0) * 100.0)
	if not ctx.colony_mode and not IsEntityDead(ped) then SetEntityHealth(ped, S.expected) end
	SetPlayerSprint(PlayerId(), fx.sprint ~= false)
	SetPedMoveRateOverride(ped, fx.limp and 0.82 or 1.0)
end

local function damage_kind(ped)
	if IsPedFalling(ped) then return "fall" end
	if HasEntityBeenDamagedByAnyPed(ped) then ClearEntityLastDamageEntity(ped); return "bullet" end
	return "blunt"
end

function S.step()
	local ped = PlayerPedId()
	local now = GetGameTimer()
	if not DoesEntityExist(ped) then return end
	-- death
	if IsEntityDead(ped) then
		if not S.dead then
			S.dead, S.died_at = true, now
			S.stats.deaths = S.stats.deaths + 1
			ctx.send({ type = "ped_died", id = "player", cause = "killed" })
		elseif now - S.died_at > 6000 then
			S.respawn()
		end
		return
	end
	-- damage the game dealt that nobody reported yet
	if S.expected and not ctx.colony_mode then
		local hp = GetEntityHealth(ped)
		if hp < S.expected - 1 then
			S.stats.damage = S.stats.damage + 1
			ctx.send({ type = "player_damage", amount = S.expected - hp, kind = damage_kind(ped) })
			SetEntityHealth(ped, S.expected)
		end
	end
	-- position (sim space). In colony view the camera focus is the observer (camera.lua keeps ctx.player_sim current).
	local sx, sy
	if ctx.colony_mode then
		sx, sy = ctx.player_sim.x, ctx.player_sim.y
	else
		local p = GetEntityCoords(ped)
		sx, sy = ctx.to_sim(p.x, p.y)
		ctx.player_sim.x, ctx.player_sim.y = sx, sy
	end
	local moved = S.last_pos and math.sqrt((sx - S.last_pos.x) ^ 2 + (sy - S.last_pos.y) ^ 2) or 1e9
	if moved > 20.0 or now - S.last_report >= 1000 then
		S.last_pos, S.last_report = { x = sx, y = sy }, now
		S.stats.reports = S.stats.reports + 1
		ctx.send({ type = "player_state", pos = { x = sx, y = sy, z = 0.0 }, moving = (GetEntitySpeed(ped) > 1.0) })
	end
end

function S.respawn()
	local x, y, z = ctx.to_game(0.0, 0.0, 0.0)
	NetworkResurrectLocalPlayer(x + 4.0, y, z + 1.0, 0.0, true, false)
	ClearPedBloodDamage(PlayerPedId())
	S.dead = false
	S.stats.respawns = S.stats.respawns + 1
	TriggerServerEvent(P.NET.ui_action, "player_respawn", {})
end

function S.cleanup()
	local ped = PlayerPedId()
	if DoesEntityExist(ped) then SetPedMoveRateOverride(ped, 1.0) end
	SetPlayerSprint(PlayerId(), true)
	S.fx, S.expected = nil, nil
end
ctx.on_cleanup("survival", S.cleanup)

function S.start_threads()
	CreateThread(function()
		while ctx.running do
			Wait(200)
			S.step()
		end
	end)
end

return S
