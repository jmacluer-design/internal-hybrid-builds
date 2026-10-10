-- fivem/tests/mock_natives.lua : the fake natives for the client side of tests/mock.lua (the server side only needs runtime globals).
-- Every native the resource uses is implemented here (tests/native_coverage_test.lua proves it against tools/native_check.lua's list); an unknown PascalCase
-- global raises "mock: not implemented", so a new native cannot sneak into the code without a mock. See mock.lua for what mocks cannot prove.
return function(Mock)
	local unpack = table.unpack or unpack

	function Mock:raymath()
		if self._ray then return self._ray end
		local f = assert(self.real_load(assert(io.open(self.root .. "/shared/raymath.lua", "rb")):read("*a"), "@shared/raymath.lua"))
		self._ray = f()
		return self._ray
	end

	function Mock:install_client_natives(side)
		local m, env = self, side.env
		local N = {}
		local function count(name) m.calls[name] = (m.calls[name] or 0) + 1 end
		local ground = Mock.terrain

		-- entity lookup with stale / bad handle accounting
		m.stale_calls = m.stale_calls or {}
		local function ent(h, name)
			local e = m.ents[h]
			if not e then m.stale_calls[name] = (m.stale_calls[name] or 0) + 1; m.bad_handle = true; return nil end
			if not e.exists then m.stale_calls[name] = (m.stale_calls[name] or 0) + 1; return nil end
			return e
		end
		local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end
		local function task(e, name, extra)
			e.task = name
			e.dest, e.follow, e.scenario = nil, nil, nil
			e.task_log = e.task_log or {}
			local rec = { name = name, t = m.t }
			if extra then for k, v in pairs(extra) do rec[k] = v end end
			e.task_log[#e.task_log + 1] = rec
			if #e.task_log > 60 then table.remove(e.task_log, 1) end
			m.task_counts = m.task_counts or {}
			m.task_counts[name] = (m.task_counts[name] or 0) + 1
		end

		-- ------------------------------------------------------------------------------------------------------------ models / anims
		N.GetHashKey = function(name)
			if type(name) == "number" then return name end
			local h = Mock.joaat(name)
			m.models[h] = m.models[h] or { name = name }
			return h
		end
		local function model_ok(h)
			local mm = m.models[h]
			return mm and not m.invalid_models[mm.name:lower()]
		end
		N.IsModelInCdimage = function(h) return model_ok(h) and true or false end
		N.IsModelValid = function(h) return model_ok(h) and true or false end
		N.RequestModel = function(h) local mm = m.models[h]; if mm and not mm.req_t then mm.req_t = m.t end end
		N.HasModelLoaded = function(h) local mm = m.models[h]; return (mm and mm.req_t and model_ok(h) and m.t - mm.req_t >= m.model_load_ms) and true or false end
		N.SetModelAsNoLongerNeeded = function(h) local mm = m.models[h]; if mm then mm.req_t = nil end end
		m.anims = {}
		N.DoesAnimDictExist = function(d) return not (m.missing_anims and m.missing_anims[d]) end
		N.RequestAnimDict = function(d) m.anims[d] = m.anims[d] or m.t end
		N.HasAnimDictLoaded = function(d) return m.anims[d] ~= nil and m.t - m.anims[d] >= 30 end
		N.RequestAnimSet = function(d) m.anims["set:" .. d] = m.anims["set:" .. d] or m.t end
		N.HasAnimSetLoaded = function(d) return m.anims["set:" .. d] ~= nil and m.t - m.anims["set:" .. d] >= 30 end

		-- ------------------------------------------------------------------------------------------------------------ pool + creation
		N.GetGamePool = function(kind)
			count("GetGamePool")
			local out = {}
			if kind == "CPed" then
				for _, e in ipairs(m:entities("ped")) do out[#out + 1] = e.handle end
				for i = 1, m.ambient_peds do out[#out + 1] = -i end
			end
			return out
		end
		local function check_loaded(h, what)
			if not (m.models[h] and m.models[h].req_t and model_ok(h) and m.t - m.models[h].req_t >= m.model_load_ms) then
				error("mock: " .. what .. " with a model that is not loaded (" .. tostring(m.models[h] and m.models[h].name) .. ")", 3)
			end
		end
		N.CreatePed = function(ptype, model, x, y, z, heading, is_net, script_host)
			count("CreatePed")
			check_loaded(model, "CreatePed")
			if m.refuse_create_ped then return 0 end
			m.created.peds = m.created.peds + 1
			local e = m:new_entity("ped", { x = x, y = y, z = z, heading = heading, model = m.models[model].name, mine = true, net = is_net, weapons = {}, maxhealth = 200 })
			return e.handle
		end
		N.CreateObjectNoOffset = function(model, x, y, z, is_net, script_host, dynamic)
			count("CreateObjectNoOffset")
			check_loaded(model, "CreateObjectNoOffset")
			m.created.objects = m.created.objects + 1
			return m:new_entity("object", { x = x, y = y, z = z, model = m.models[model].name, mine = true, net = is_net }).handle
		end
		N.DeleteEntity = function(h)
			count("DeleteEntity")
			local e = m.ents[h]
			if not e then m.bad_handle = true; return end
			if not e.exists then m.stale_calls.DeleteEntity = (m.stale_calls.DeleteEntity or 0) + 1; return end
			if e.player then error("mock: the resource tried to delete the player's own ped") end
			e.exists = false
			e.deleted_t = m.t
			for _, o in pairs(m.ents) do if o.attached == h then o.attached = nil end end
		end
		N.DoesEntityExist = function(h) local e = m.ents[h]; return (e and e.exists) and true or false end
		N.SetEntityAsMissionEntity = function(h) local e = ent(h, "SetEntityAsMissionEntity"); if e then e.mission = true end end
		N.PlayerPedId = function() return m.player.ped.handle end
		N.PlayerId = function() return m.player.id end
		N.GetEntityCoords = function(h) local e = ent(h, "GetEntityCoords"); if not e then return { x = 0.0, y = 0.0, z = 0.0 } end return { x = e.x, y = e.y, z = e.z } end
		N.SetEntityCoordsNoOffset = function(h, x, y, z) local e = ent(h, "SetEntityCoordsNoOffset"); if e then e.x, e.y, e.z = x, y, z; e.snapped = (e.snapped or 0) + 1 end end
		N.GetEntityHealth = function(h) local e = ent(h, "GetEntityHealth"); return e and e.health or 0 end
		N.SetEntityHealth = function(h, v) local e = ent(h, "SetEntityHealth"); if e then if e.dead and not e.player then return end e.health = v; if v <= 100 then e.dead = true end end end -- like the game: a dead ped cannot be healed by SetEntityHealth
		N.SetEntityMaxHealth = function(h, v) local e = ent(h, "SetEntityMaxHealth"); if e then e.maxhealth = v end end
		N.SetPedMaxHealth = N.SetEntityMaxHealth
		N.IsPedDeadOrDying = function(h) local e = m.ents[h]; return (not e) or (not e.exists) or e.dead or e.health <= 100 end
		N.IsEntityDead = function(h) local e = m.ents[h]; return (not e) or (not e.exists) or e.dead or e.health <= 100 end
		N.GetEntitySpeed = function(h) local e = ent(h, "GetEntitySpeed"); return e and (e.speed_now or 0.0) or 0.0 end
		N.FreezeEntityPosition = function(h, v) local e = ent(h, "FreezeEntityPosition"); if e then e.frozen = v end end
		N.SetEntityInvincible = function(h, v) local e = ent(h, "SetEntityInvincible"); if e then e.invincible = v end end
		N.SetEntityAlpha = function(h, a) local e = ent(h, "SetEntityAlpha"); if e then e.alpha = a; e.alpha_calls = (e.alpha_calls or 0) + 1 end end
		N.ResetEntityAlpha = function(h) local e = ent(h, "ResetEntityAlpha"); if e then e.alpha = 255 end end
		N.SetEntityCollision = function(h, a) local e = ent(h, "SetEntityCollision"); if e then e.collision = a end end
		N.PlaceObjectOnGroundProperly = function(h) local e = ent(h, "PlaceObjectOnGroundProperly"); if e then e.z = ground(e.x, e.y); return true end return false end
		N.AttachEntityToEntity = function(a, b) local e = ent(a, "AttachEntityToEntity"); if e then e.attached = b end end
		N.DetachEntity = function(a) local e = ent(a, "DetachEntity"); if e then e.attached = nil end end
		N.GetPedBoneIndex = function() return 1 end
		N.SetEntityDrawOutline = function(h, v) local e = ent(h, "SetEntityDrawOutline"); if e then e.outline = v end end
		N.SetEntityDrawOutlineColor = function(r, g, b, a) m.outline_color = { r, g, b, a } end
		N.ClearEntityLastDamageEntity = function(h) local e = ent(h, "ClearEntityLastDamageEntity"); if e then e.damaged_by_ped = false end end
		N.HasEntityBeenDamagedByAnyPed = function(h) local e = ent(h, "HasEntityBeenDamagedByAnyPed"); return e and e.damaged_by_ped or false end
		N.GetPedSourceOfDeath = function(h) local e = m.ents[h]; return e and e.killer or 0 end
		N.SetPedToRagdoll = function(h, t1) local e = ent(h, "SetPedToRagdoll"); if e then e.ragdoll_until = m.t + t1; e.ragdolls = (e.ragdolls or 0) + 1 end end
		N.IsPedRagdoll = function(h) local e = m.ents[h]; return e and e.ragdoll_until and m.t < e.ragdoll_until or false end
		N.IsPedFalling = function(h) local e = m.ents[h]; return e and e.falling or false end

		-- ------------------------------------------------------------------------------------------------------------ tasks
		N.ClearPedTasks = function(h) local e = ent(h, "ClearPedTasks"); if e then task(e, "clear") end end
		N.TaskGoToCoordAnyMeans = function(h, x, y, z, speed)
			local e = ent(h, "TaskGoToCoordAnyMeans"); if not e then return end
			task(e, "go_to_coord", { x = x, y = y, z = z, speed = speed })
			e.dest, e.speed = { x = x, y = y, z = z }, speed
		end
		N.TaskGoToEntity = function(h, target, duration, dist_, speed)
			local e = ent(h, "TaskGoToEntity"); if not e then return end
			task(e, "go_to_entity", { target = target, speed = speed })
			e.follow, e.speed = target, speed
		end
		N.TaskWanderStandard = function(h) local e = ent(h, "TaskWanderStandard"); if e then task(e, "wander") end end
		N.TaskStartScenarioInPlace = function(h, name) local e = ent(h, "TaskStartScenarioInPlace"); if e then task(e, "scenario", { scenario = name }); e.scenario = name end end
		N.TaskCombatHatedTargetsAroundPed = function(h, radius) local e = ent(h, "TaskCombatHatedTargetsAroundPed"); if e then task(e, "combat", { radius = radius }) end end
		N.TaskSmartFleePed = function(h, from) local e = ent(h, "TaskSmartFleePed"); if e then task(e, "flee", { from = from }) end end
		N.TaskPlayAnim = function(h, dict, anim) local e = ent(h, "TaskPlayAnim"); if e then e.anim = dict .. "/" .. anim; e.anim_plays = (e.anim_plays or 0) + 1 end end
		N.SetBlockingOfNonTemporaryEvents = function(h, v) local e = ent(h, "SetBlockingOfNonTemporaryEvents"); if e then e.blocking = v end end
		N.SetPedKeepTask = function(h, v) local e = ent(h, "SetPedKeepTask"); if e then e.keep_task = v end end
		N.GiveWeaponToPed = function(h, hash, ammo) local e = ent(h, "GiveWeaponToPed"); if e then e.weapons[hash] = (e.weapons[hash] or 0) + ammo end end
		N.SetCurrentPedWeapon = function(h, hash) local e = ent(h, "SetCurrentPedWeapon"); if e then e.weapon = hash end end

		-- ------------------------------------------------------------------------------------------------------------ ped setters (state recorded for assertions)
		local function setter(name, field)
			N[name] = function(h, a, b)
				local e = ent(h, name)
				if e then
					e.cfg = e.cfg or {}
					if name == "SetPedCombatAttributes" or name == "SetPedFleeAttributes" or name == "SetPedConfigFlag" then e.cfg[name .. ":" .. tostring(a)] = b else e.cfg[name] = a end
				end
			end
		end
		for _, nm in ipairs({ "SetPedAccuracy", "SetPedAlertness", "SetPedCombatMovement", "SetPedCombatRange", "SetPedDiesWhenInjured", "SetPedDropsWeaponsWhenDead",
			"SetPedHearingRange", "SetPedMoveRateOverride", "SetPedMovementClipset", "SetPedRagdollBlockingFlags", "SetPedSeeingRange", "SetPedSuffersCriticalHits",
			"DisablePedPainAudio", "StopPedSpeaking", "ApplyPedDamagePack", "SetPedCombatAttributes", "SetPedFleeAttributes", "SetPedConfigFlag" }) do setter(nm) end
		N.SetPedRelationshipGroupHash = function(h, g) local e = ent(h, "SetPedRelationshipGroupHash"); if e then e.group = g end end

		-- scripted player state (tests flip these through m.player_*)
		N.IsPedShooting = function(h)
			local e = m.ents[h]
			return e and e.exists and e.shoot_frame == m.frame_no or false
		end
		N.GetCurrentPedWeapon = function(h) local e = m.ents[h]; return true, (e and e.weapon) or -1569615261 end
		N.GetWeapontypeGroup = function(hash) return (m.weapon_groups and m.weapon_groups[hash]) or 416676503 end
		N.IsPedCurrentWeaponSilenced = function(h) local e = m.ents[h]; return e and e.silenced or false end
		N.IsPedSprinting = function(h) local e = m.ents[h]; return e and e.sprinting or false end
		N.IsPedDucking = function(h) local e = m.ents[h]; return e and e.ducking or false end
		N.GetPedStealthMovement = function(h) local e = m.ents[h]; return e and e.ducking or false end
		N.IsPedInAnyVehicle = function(h) local e = m.ents[h]; return e and e.vehicle ~= nil or false end
		N.GetVehiclePedIsIn = function(h) local e = m.ents[h]; return e and e.vehicle or 0 end
		N.IsVehicleSirenOn = function(v) return m.vehicle_state and m.vehicle_state.siren or false end
		N.IsHornActive = function(v) return m.vehicle_state and m.vehicle_state.horn or false end
		N.IsPedInMeleeCombat = function(h) local e = m.ents[h]; return e and e.melee or false end
		N.IsExplosionInSphere = function(kind, x, y, z, r)
			local ex = m.explosion
			return ex and math.sqrt((ex.x - x) ^ 2 + (ex.y - y) ^ 2 + (ex.z - z) ^ 2) <= r or false
		end
		N.NetworkResurrectLocalPlayer = function(x, y, z)
			local p = m.player.ped
			p.x, p.y, p.z, p.health, p.dead = x, y, z, 200, false
			m.resurrects = (m.resurrects or 0) + 1
		end
		N.ClearPedBloodDamage = function() end
		N.SetPlayerSprint = function(_, v) m.player.sprint_allowed = v end
		N.SetPlayerHealthRechargeMultiplier = function(_, v) m.env.health_recharge = v end
		N.ShakeGameplayCam = function() m.shakes = (m.shakes or 0) + 1 end
		N.PlaySoundFrontend = function(id, name, set) m.sounds = m.sounds or {}; m.sounds[#m.sounds + 1] = name end

		-- ------------------------------------------------------------------------------------------------------------ ground / probes / cameras
		N.GetGroundZFor_3dCoord = function(x, y, z)
			if m.no_ground then return false, 0.0 end
			return true, ground(x, y)
		end
		N.RequestCollisionAtCoord = function() end
		N.GetAspectRatio = function() return 16 / 9 end
		N.GetFrameTime = function() return m.frame_ms / 1000 end
		N.GetGameplayCamRot = function() return { x = 0.0, y = 0.0, z = m.player.heading } end
		N.HideHudAndRadarThisFrame = function() m.hud_hidden_frames = (m.hud_hidden_frames or 0) + 1 end
		N.CreateCam = function(name, active)
			m.created.cams = m.created.cams + 1
			return m:new_entity("cam", { name = name, x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0, fov = 50, active = false, mine = true }).handle
		end
		N.SetCamCoord = function(h, x, y, z) local e = ent(h, "SetCamCoord"); if e then e.x, e.y, e.z = x, y, z end end
		N.SetCamRot = function(h, rx, ry, rz) local e = ent(h, "SetCamRot"); if e then e.rx, e.ry, e.rz = rx, ry, rz end end
		N.SetCamFov = function(h, f) local e = ent(h, "SetCamFov"); if e then e.fov = f end end
		N.SetCamActive = function(h, v) local e = ent(h, "SetCamActive"); if e then e.active = v; if v then m.cams.active = h end end end
		N.RenderScriptCams = function(render) m.cams.rendering = render end
		N.DestroyCam = function(h) local e = ent(h, "DestroyCam"); if e then e.exists = false; if m.cams.active == h then m.cams.active = nil end end end
		N.SetFocusArea = function(x, y, z) m.focus = { x = x, y = y, z = z } end
		N.ClearFocus = function() m.focus = nil end
		N.GetScreenCoordFromWorldCoord = function(x, y, z)
			local c = m.cams.active and m.ents[m.cams.active]
			if not c or not c.exists then return false, 0.0, 0.0 end
			local sx, sy = m:raymath().project(c.x, c.y, c.z, c.rx, c.rz, c.fov, 16 / 9, x, y, z)
			if not sx then return false, 0.0, 0.0 end
			return (sx >= 0 and sx <= 1 and sy >= 0 and sy <= 1), sx, sy
		end
		N.StartShapeTestLosProbe = function(x1, y1, z1, x2, y2, z2)
			local len = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2 + (z2 - z1) ^ 2)
			local hit, hx, hy, hz = 0, 0.0, 0.0, 0.0
			local steps = math.floor(len)
			local prev = z1 - ground(x1, y1)
			for i = 1, steps do
				local t = i / steps
				local px, py, pz = x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, z1 + (z2 - z1) * t
				if pz <= ground(px, py) then hit, hx, hy, hz = 1, px, py, ground(px, py); break end
			end
			m.handle = m.handle + 1
			m.shape_tests[m.handle] = { hit = hit, x = hx, y = hy, z = hz }
			return m.handle
		end
		N.GetShapeTestResult = function(h)
			local r = m.shape_tests[h]
			if not r then return 0, 0, { x = 0.0, y = 0.0, z = 0.0 }, { x = 0.0, y = 0.0, z = 1.0 }, 0 end
			return 2, r.hit, { x = r.x, y = r.y, z = r.z }, { x = 0.0, y = 0.0, z = 1.0 }, 0
		end
		N.DrawMarker = function() m.markers = m.markers + 1 end
		N.DrawLightWithRange = function() m.lights = m.lights + 1 end

		-- ------------------------------------------------------------------------------------------------------------ relationship groups
		N.AddRelationshipGroup = function(name)
			local h = Mock.joaat(name)
			m.models[h] = m.models[h] or { name = name }
			m.rel_groups[h] = name
			return true, h
		end
		N.SetRelationshipBetweenGroups = function(level, a, b) m.rels[a .. ":" .. b] = level end
		N.RemoveRelationshipGroup = function(h)
			m.rel_groups[h] = nil
			for k in pairs(m.rels) do
				local a, b = k:match("^(%d+):(%d+)$")
				if tonumber(a) == h or tonumber(b) == h then m.rels[k] = nil end
			end
		end

		-- ------------------------------------------------------------------------------------------------------------ blips
		N.AddBlipForCoord = function(x, y, z) m.created.blips = m.created.blips + 1; return m:new_entity("blip", { x = x, y = y, z = z, mine = true }).handle end
		N.RemoveBlip = function(h) local e = ent(h, "RemoveBlip"); if e then e.exists = false end end
		for _, nm in ipairs({ "SetBlipSprite", "SetBlipColour", "SetBlipScale", "SetBlipAsShortRange", "BeginTextCommandSetBlipName", "AddTextComponentSubstringPlayerName", "EndTextCommandSetBlipName" }) do
			N[nm] = function() end
		end

		-- ------------------------------------------------------------------------------------------------------------ world settings
		N.SetScenarioTypeEnabled = function(name, v) m.env.scenarios[name] = v end
		N.SetPedPopulationBudget = function(v) m.env.ped_budget = v end
		N.SetVehiclePopulationBudget = function(v) m.env.veh_budget = v end
		N.SetNumberOfParkedVehicles = function(v) m.env.parked = v end
		N.SetRandomBoats = function(v) m.env.boats = v end
		N.SetRandomTrains = function(v) m.env.trains = v end
		N.SetGarbageTrucks = function(v) m.env.garbage = v end
		N.SetCreateRandomCops = function(v) m.env.random_cops = v end
		N.SetCreateRandomCopsNotOnScenarios = function(v) m.env.random_cops_ns = v end
		N.SetCreateRandomCopsOnScenarios = function(v) m.env.random_cops_s = v end
		N.EnableDispatchService = function(i, v) m.env.dispatch[i] = v end
		N.SetDispatchCopsForPlayer = function(_, v) m.env.dispatch_cops = v end
		N.SetMaxWantedLevel = function(v) m.env.wanted = v end
		for _, nm in ipairs({ "SetPedDensityMultiplierThisFrame", "SetScenarioPedDensityMultiplierThisFrame", "SetVehicleDensityMultiplierThisFrame",
			"SetRandomVehicleDensityMultiplierThisFrame", "SetParkedVehicleDensityMultiplierThisFrame" }) do
			N[nm] = function() m.env.density_calls = m.env.density_calls + 1 end
		end
		N.SetBlackout = function(v) m.env.blackout = v end
		N.NetworkOverrideClockTime = function(h, mi, s) m.env.clock = { h = h, m = mi, s = s } end
		N.NetworkClearClockTimeOverride = function() m.env.clock = nil end
		N.PauseClock = function(v) m.env.clock_paused = v end
		N.SetMillisecondsPerGameMinute = function(ms) m.env.ms_per_min = ms end
		N.SetWeatherTypeNowPersist = function(name) m.env.weather = name end
		N.ClearWeatherTypePersist = function() m.env.weather = nil end
		N.SetNuiFocus = function(a, b) m.env.nui_focus = a; m.env.nui_cursor = b end

		-- ------------------------------------------------------------------------------------------------------------ NUI (runtime globals in FiveM)
		env.SendNUIMessage = function(msg)
			count("SendNUIMessage")
			local ok, why = m:util().msgpack_safe(msg)
			if not ok then m.net.bad_payloads[#m.net.bad_payloads + 1] = "SendNUIMessage: " .. why end
			local okj, js = pcall(m:json().encode, msg)
			if not okj then m.net.bad_payloads[#m.net.bad_payloads + 1] = "SendNUIMessage json: " .. tostring(js) end
			m.nui_msgs[#m.nui_msgs + 1] = { action = msg.action, data = msg.data }
			if #m.nui_msgs > 4000 then table.remove(m.nui_msgs, 1) end
		end
		env.RegisterNUICallback = function(name, fn) m.script.nui_cb[name] = fn end

		-- install, and make a missing native loud
		for k, v in pairs(N) do
			env[k] = function(...) count(k); return v(...) end
		end
		setmetatable(env, { __index = function(_, k)
			if type(k) == "string" and k:match("^%u") then error("mock: native/global '" .. k .. "' is not implemented in the mock", 2) end
			return nil
		end })
		m.native_names = N
	end

	-- ---------------------------------------------------------------------------------------------------------------- world physics
	function Mock:physics(dt)
		self.frame_no = (self.frame_no or 0) + 1
		local sec = dt / 1000
		local ents = self.ents
		for _, e in pairs(ents) do
			if e.exists and e.kind == "ped" and not e.player and not e.dead and e.health > 100 then
				e.speed_now = 0.0
				if not (e.ragdoll_until and self.t < e.ragdoll_until) and not e.frozen then
					local target = e.dest
					if e.follow then
						local f = ents[e.follow]
						if f and f.exists then target = { x = f.x, y = f.y, z = f.z } end
					end
					if target then
						local dx, dy = target.x - e.x, target.y - e.y
						local d = math.sqrt(dx * dx + dy * dy)
						local stop = e.follow and 0.9 or 0.6
						if d > stop then
							local v = 1.4 * (e.speed or 1.0) * (self.walk_scale or 1.0)
							local step = math.min(d - stop, v * sec)
							e.x, e.y = e.x + dx / d * step, e.y + dy / d * step
							e.z = Mock.terrain(e.x, e.y)
							e.speed_now = v
						elseif e.dest and not e.follow then
							e.dest = nil
							e.arrived = (e.arrived or 0) + 1
						end
					end
				end
			end
		end
	end

	-- ---------------------------------------------------------------------------------------------------------------- scripted gameplay helpers for tests
	function Mock:player_shoot(weapon_group, silenced)
		local p = self.player.ped
		p.shoot_frame = (self.frame_no or 0) + 1
		p.silenced = silenced or false
		self.weapon_groups = self.weapon_groups or {}
		self.weapon_groups[-1569615261] = weapon_group or 416676503
	end
	function Mock:player_move_to(x, y) local p = self.player.ped; p.x, p.y, p.z = x, y, Mock.terrain(x, y) end
	function Mock:damage(handle, amount, killer)
		local e = self.ents[handle]
		e.health = e.health - amount
		e.damaged_by_ped = true
		if e.health <= 100 then e.dead = true; e.killer = killer end
	end
	function Mock:kill(handle, killer) local e = self.ents[handle]; e.health = 0; e.dead = true; e.killer = killer end
end
