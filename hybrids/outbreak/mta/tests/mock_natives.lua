-- mta/tests/mock_natives.lua : the fake MTA functions for tests/mock_mta.lua. Every function the resource uses is implemented here (tests/mock_coverage_test.lua proves it against
-- tools/function_check.lua's list); a function that exists in the mock but not on that side in the real MTA source is NOT exposed to that side (so a wrong-side call is a nil call).
-- See mock_mta.lua for what mocks cannot prove.
return function(Mock, K)
	local EL, is_el, terrain = K.EL, K.is_el, K.terrain
	local unpack = table.unpack or unpack

	-- positions: peds stand 1 m above the ground
	local STREAM = 250.0

	local function dist2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

	function Mock:install_natives(side)
		local m, env = self, side.env
		local N = {}
		local is_client = side.name == "client"
		local function count(name) m.calls[name] = (m.calls[name] or 0) + 1 end

		-- strict element argument: raises like MTA's "Bad argument @ 'fn' [Expected element at argument 1, got ...]" on a destroyed / wrong element
		local function el(v, fname, kinds)
			if not is_el(v) then error(string.format("Bad argument @ '%s' [Expected element at argument 1, got %s]", fname, type(v)), 3) end
			if v.destroyed then error(string.format("Bad argument @ '%s' [Expected element at argument 1, got destroyed element]", fname), 3) end
			if kinds and not kinds[v.type] then error(string.format("Bad argument @ '%s' [Expected %s at argument 1, got %s]", fname, next(kinds), v.type), 3) end
			return v
		end
		local PEDLIKE = { ped = true, player = true }
		local PEDONLY = { ped = true }
		local function pos_of(e) return { x = e.x, y = e.y, z = e.z } end

		local function streamed_in(e)
			local p = m.player
			return p and dist2(e, p) <= STREAM
		end

		-- ------------------------------------------------------------------------------------------------------------ resource / misc (both sides)
		N.getThisResource = function() return m.resource end
		N.getResourceName = function(r) return r and r.name or "outbreak" end
		N.getTickCount = function() return m.t end
		N.getRootElement = function() return m.root end
		N.getResourceRootElement = function() return m.resourceRoot end
		N.outputDebugString = function(text, level) m.log[#m.log + 1] = string.format("[%s debug %s] %s", side.name, tostring(level or 3), tostring(text)) end
		N.outputServerLog = function(text) m.log[#m.log + 1] = "[server log] " .. tostring(text) end
		N.outputChatBox = function(text, to) m.chat[#m.chat + 1] = { text = tostring(text), to = to, side = side.name } end
		N.loadstring = nil -- env-level (mock_mta.lua)
		N.get = function(name)
			count("get")
			local v = m.settings[name]
			if v == nil then return false end
			return v
		end
		N.hasObjectPermissionTo = function(obj, right, default)
			if is_el(obj) and obj.type == "player" then return m.acl[tostring(obj.name) .. ":" .. right] == true end
			return default or false
		end

		-- ------------------------------------------------------------------------------------------------------------ timers
		N.setTimer = function(fn, interval, times, ...)
			count("setTimer")
			if type(fn) ~= "function" or type(interval) ~= "number" or interval < 50 then return false end
			side.next_timer = side.next_timer + 1
			local t = setmetatable({ id = side.next_timer, fn = fn, interval = interval, times = times or 1, next_t = m.t + interval, args = { ... }, n = select("#", ...), dead = false, side = side.name },
				{ __tostring = function(t) return "timer:" .. t.id end, __timer = true })
			side.timers[t.id] = t
			return t
		end
		N.killTimer = function(t) if type(t) == "table" and getmetatable(t) and getmetatable(t).__timer and not t.dead then t.dead = true; return true end return false end
		N.isTimer = function(t) return type(t) == "table" and getmetatable(t) ~= nil and getmetatable(t).__timer == true and not t.dead end

		-- ------------------------------------------------------------------------------------------------------------ events
		N.addEvent = function(name, remote)
			count("addEvent")
			if type(name) ~= "string" then error("Bad argument @ 'addEvent' [Expected string at argument 1]", 2) end
			local ex = side.events[name]
			if ex and ex.builtin then return false end
			side.events[name] = { remote = remote == true }
			return true
		end
		N.addEventHandler = function(name, attached, fn, propagate, priority)
			count("addEventHandler")
			if type(name) ~= "string" or not is_el(attached) or type(fn) ~= "function" then error("Bad argument @ 'addEventHandler'", 2) end
			if not side.events[name] then
				m.warnings[#m.warnings + 1] = string.format("[%s] addEventHandler: event '%s' is not added", side.name, name)
				return false
			end
			local l = side.handlers[name]
			if not l then l = {}; side.handlers[name] = l end
			l[#l + 1] = { el = attached, fn = fn, propagate = propagate ~= false, removed = false }
			return true
		end
		N.removeEventHandler = function(name, attached, fn)
			local l = side.handlers[name]
			if not l then return false end
			for _, h in ipairs(l) do if h.el == attached and h.fn == fn and not h.removed then h.removed = true; return true end end
			return false
		end
		N.cancelEvent = function() side.cancel_flag = true; return true end
		N.triggerEvent = function(name, source, ...) return m:trigger(side, name, source, ...) end
		N.triggerClientEvent = function(...)
			count("triggerClientEvent")
			local n = select("#", ...)
			local args = { ... }
			local to, name, source, first
			if type(args[1]) == "string" then to, name, source, first = m.root, args[1], args[2], 3 else to, name, source, first = args[1], args[2], args[3], 4 end
			if type(name) ~= "string" then error("Bad argument @ 'triggerClientEvent' [Expected string]", 2) end
			if not is_el(source) then error("Bad argument @ 'triggerClientEvent' [Expected element at argument 3]", 2) end
			local targets = {}
			if is_el(to) and to.type == "player" then targets[1] = to else for _, p in ipairs(m.players) do if not p.destroyed then targets[#targets + 1] = p end end end
			for _, p in ipairs(targets) do
				if p.local_to_client then m:send_remote("client", name, source, nil, p, unpack(args, first, n))
				else p.inbox[#p.inbox + 1] = { name = name, args = { unpack(args, first, n) } } end -- a player that has no client sandbox here: remember what the server sent
			end
			return true
		end
		N.triggerServerEvent = function(name, source, ...)
			count("triggerServerEvent")
			if type(name) ~= "string" or not is_el(source) then error("Bad argument @ 'triggerServerEvent'", 2) end
			return m:send_remote("server", name, source, m.player, nil, ...)
		end

		-- ------------------------------------------------------------------------------------------------------------ elements
		N.isElement = function(v) return is_el(v) and not v.destroyed end
		N.getElementType = function(e) return el(e, "getElementType").type end
		N.destroyElement = function(e)
			el(e, "destroyElement")
			if e == m.root or e == m.resourceRoot or e.type == "player" then return false end
			return m:destroy_element(e)
		end
		N.getElementParent = function(e) return el(e, "getElementParent").parent end
		N.getElementData = function(e, k) return el(e, "getElementData").data[k] end
		N.setElementData = function(e, k, v) el(e, "setElementData").data[k] = v; return true end
		N.getElementPosition = function(e) el(e, "getElementPosition"); return e.x, e.y, e.z end
		N.setElementPosition = function(e, x, y, z)
			el(e, "setElementPosition")
			if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then error("Bad argument @ 'setElementPosition' [Expected number]", 2) end
			e.x, e.y, e.z = x, y, z
			e.moved_by_script = (e.moved_by_script or 0) + 1
			return true
		end
		N.setElementFrozen = function(e, f) el(e, "setElementFrozen").frozen = f and true or false; return true end
		N.setElementAlpha = function(e, a) el(e, "setElementAlpha").alpha = a; e.alpha_sets = (e.alpha_sets or 0) + 1; return true end
		N.setElementCollisionsEnabled = function(e, f) el(e, "setElementCollisionsEnabled").collisions = f and true or false; return true end
		N.getElementsByType = function(kind, start, streamed)
			start = start or m.root
			local out = {}
			local function walk(e)
				for _, c in ipairs(e.children) do
					if not c.destroyed then
						local visible = (c.created_by ~= "client") or is_client
						if c.type == kind and visible and (not streamed or streamed_in(c)) then out[#out + 1] = c end
						walk(c)
					end
				end
			end
			walk(start)
			return out
		end
		N.getElementHealth = function(e) return el(e, "getElementHealth", PEDLIKE).health end
		N.setElementHealth = function(e, h)
			el(e, "setElementHealth", PEDLIKE)
			if type(h) ~= "number" then error("Bad argument @ 'setElementHealth' [Expected number]", 2) end
			if e.dead and h > 0 then return false end
			e.health = math.min(h, e.max_health or 100)
			e.health_sets = (e.health_sets or 0) + 1
			if e.health <= 0 then m:wasted(e, nil, 0, 3, false) end
			return true
		end
		N.getElementModel = function(e) return el(e, "getElementModel").model end
		N.getElementVelocity = function(e) el(e, "getElementVelocity"); return e.vx or 0.0, e.vy or 0.0, e.vz or 0.0 end
		N.isElementStreamedIn = function(e) return streamed_in(el(e, "isElementStreamedIn")) and true or false end
		N.getElementDistanceFromCentreOfMassToBaseOfModel = function(e) el(e, "getElementDistanceFromCentreOfMassToBaseOfModel"); return e.type == "object" and (m.base_offsets and m.base_offsets[e.model] or 0.5) or 1.0 end

		-- ------------------------------------------------------------------------------------------------------------ peds
		N.getValidPedModels = function()
			local out = {}
			for id = 0, 312 do if not m.invalid_ped_models[id] then out[#out + 1] = id end end
			return out
		end
		N.createPed = function(model, x, y, z, rot, synced)
			count("createPed")
			if m.fail.createPed then return false end
			if type(model) ~= "number" or m.invalid_ped_models[model] or model < 0 or model > 312 then return false end
			local live = 0
			for _, e in pairs(m.els) do if e.type == "ped" and not e.destroyed then live = live + 1 end end
			if live >= 140 then m.pool_overflow = (m.pool_overflow or 0) + 1; return false end
			m.created.peds = m.created.peds + 1
			local p = m:new_element("ped", { model = model, x = x, y = y, z = z, rz = rot or 0.0, mine = true, created_by = is_client and "client" or "server", health = 100, weapons = {}, controls = {}, stats = {},
				synced = synced ~= false, fell = false, creation_z = z }, m.resourceRoot)
			return p
		end
		N.killPed = function(ped, killer, weapon, bodypart, stealth)
			el(ped, "killPed", PEDLIKE)
			if ped.dead then return false end
			m:wasted(ped, killer, weapon or 255, bodypart or 3, stealth or false)
			return true
		end
		N.isPedDead = function(ped) return el(ped, "isPedDead", PEDLIKE).dead == true end
		N.isPedDucked = function(ped) return el(ped, "isPedDucked", PEDLIKE).ducked == true end
		N.isPedInVehicle = function(ped) return el(ped, "isPedInVehicle", PEDLIKE).vehicle ~= nil end
		N.getPedOccupiedVehicle = function(ped) return el(ped, "getPedOccupiedVehicle", PEDLIKE).vehicle or false end
		N.getPedWeaponSlot = function(ped) return el(ped, "getPedWeaponSlot", PEDLIKE).weapon_slot or 0 end
		N.setPedWalkingStyle = function(ped, style) el(ped, "setPedWalkingStyle", PEDLIKE).walk_style = style; return true end
		N.setPedRotation = function(ped, r) el(ped, "setPedRotation", PEDLIKE).rz = r % 360; return true end
		N.setPedStat = function(ped, stat, v) el(ped, "setPedStat", PEDLIKE).stats[stat] = v; if stat == 24 and v >= 1000 then ped.max_health = 176 end return true end
		N.setPedAnimation = function(ped, block, anim, time, loop, upd, intr, freeze)
			el(ped, "setPedAnimation", PEDLIKE)
			ped.anim_sets = (ped.anim_sets or 0) + 1
			if not block then ped.anim = nil else ped.anim = { block = block, name = anim, time = time, loop = loop } end
			return true
		end
		N.giveWeapon = function(ped, id, ammo, current)
			el(ped, "giveWeapon", PEDLIKE)
			ped.weapons[id] = (ped.weapons[id] or 0) + (ammo or 30)
			if current then ped.current_weapon = id end
			return true
		end
		N.getPedWeapon = function(ped) return el(ped, "getPedWeapon", PEDLIKE).current_weapon or 0 end
		N.setElementSyncer = function(ped, player, persist)
			el(ped, "setElementSyncer", PEDONLY)
			ped.syncer = player or nil
			return true
		end
		N.isElementSyncer = function(ped)
			el(ped, "isElementSyncer", PEDONLY)
			if ped.syncer ~= nil then return ped.syncer == m.player end
			return m.auto_syncer ~= false and streamed_in(ped) and true or false
		end
		N.setPedControlState = function(ped, control, state)
			count("setPedControlState")
			el(ped, "setPedControlState", PEDONLY)
			if type(control) ~= "string" or type(state) ~= "boolean" then error("Bad argument @ 'setPedControlState'", 2) end
			ped.controls[control] = state or nil
			ped.control_calls = (ped.control_calls or 0) + 1
			if control == "jump" and state then ped.jumps = (ped.jumps or 0) + 1 end
			return true
		end
		N.setPedAimTarget = function(ped, x, y, z) el(ped, "setPedAimTarget", PEDONLY).aim = { x = x, y = y, z = z }; return true end
		N.getPedMoveState = function(ped) el(ped, "getPedMoveState", PEDLIKE); return (ped == m.player) and m.player_move_state or "stand" end

		-- ------------------------------------------------------------------------------------------------------------ objects
		N.createObject = function(model, x, y, z, rx, ry, rz)
			count("createObject")
			if m.fail.createObject then return false end
			if type(model) ~= "number" or m.invalid_object_models[model] or (m.valid_object_ids and not m.valid_object_ids[model]) then return false end
			local live = 0
			for _, e in pairs(m.els) do if e.type == "object" and not e.destroyed then live = live + 1 end end
			if live >= 1200 then m.object_overflow = (m.object_overflow or 0) + 1; return false end
			m.created.objects = m.created.objects + 1
			return m:new_element("object", { model = model, x = x, y = y, z = z, rx = rx or 0.0, ry = ry or 0.0, rz = rz or 0.0, mine = true, created_by = is_client and "client" or "server" }, m.resourceRoot)
		end

		-- ------------------------------------------------------------------------------------------------------------ game clock / weather (server and client)
		N.getTime = function() local t = math.floor(m.world.minutes) % 1440; return math.floor(t / 60), t % 60 end
		N.setTime = function(h, mi) m.world.minutes = h * 60 + mi; m.world.sets = m.world.sets + 1; return true end
		N.getMinuteDuration = function() return m.world.minute_ms end
		N.setMinuteDuration = function(ms) if type(ms) ~= "number" or ms < 50 then return false end m.world.minute_ms = ms; return true end
		N.getWeather = function() return m.world.weather, m.world.weather_blend end
		N.setWeather = function(id) m.world.weather = id; m.world.weather_blend = nil; return true end
		N.setWeatherBlended = function(id) m.world.weather_blend = id; return true end

		-- ------------------------------------------------------------------------------------------------------------ players, teams, spawning (server)
		N.getPlayerName = function(p) return el(p, "getPlayerName", { player = true }).name end
		N.spawnPlayer = function(p, x, y, z, rot, skin)
			el(p, "spawnPlayer", { player = true })
			p.x, p.y, p.z, p.rz, p.model, p.health, p.dead, p.spawned = x, y, z, rot or 0.0, skin or 0, 100, false, true
			p.spawns = (p.spawns or 0) + 1
			m:trigger(side, "onPlayerSpawn", p, x, y, z, rot, nil, skin)
			return true
		end
		N.fadeCamera = function(p, fade_in) el(p, "fadeCamera", { player = true }).faded_in = fade_in; return true end
		N.createTeam = function(name, r, g, b) count("createTeam"); return m:new_element("team", { name = name, mine = true, created_by = "server", friendly_fire = true }, m.resourceRoot) end
		N.setTeamFriendlyFire = function(t, f) el(t, "setTeamFriendlyFire", { team = true }).friendly_fire = f; return true end
		N.setPlayerTeam = function(p, t) el(p, "setPlayerTeam", { player = true }).team = t; return true end
		N.addCommandHandler = function(name, fn, restricted, case)
			count("addCommandHandler")
			if type(name) ~= "string" or type(fn) ~= "function" then error("Bad argument @ 'addCommandHandler'", 2) end
			m.commands[side.name][name] = { fn = fn, restricted = restricted == true }
			return true
		end

		-- ------------------------------------------------------------------------------------------------------------ files (resource-relative paths; writes stay in memory)
		local function visible(path)
			local overlay = m.fs[side.name][path]
			if overlay == false then return false end
			if overlay ~= nil then return true end
			if is_client and not m.client_files[path] then return false end
			local f = io.open(m.root_dir .. "/" .. path, "rb")
			if f then f:close(); return true end
			return false
		end
		local function content(path)
			local overlay = m.fs[side.name][path]
			if type(overlay) == "string" then return overlay end
			local f = io.open(m.root_dir .. "/" .. path, "rb")
			local s = f:read("*a")
			f:close()
			return s
		end
		m.open_files = m.open_files or 0
		N.fileExists = function(path) count("fileExists"); return type(path) == "string" and visible(path) end
		N.fileOpen = function(path, readonly)
			count("fileOpen")
			if m.fail.fileOpen or type(path) ~= "string" or not visible(path) then return false end
			m.open_files = m.open_files + 1
			return m:new_element("file", { path = path, data = content(path), pos = 0, readonly = readonly == true, mine = true, writing = false }, m.resourceRoot)
		end
		N.fileCreate = function(path)
			count("fileCreate")
			if m.fail.fileCreate or type(path) ~= "string" then return false end
			if is_client then return false end
			m.fs[side.name][path] = ""
			m.open_files = m.open_files + 1
			return m:new_element("file", { path = path, data = "", pos = 0, readonly = false, mine = true, writing = true }, m.resourceRoot)
		end
		N.fileGetSize = function(f) return #el(f, "fileGetSize", { file = true }).data end
		N.fileRead = function(f, n)
			el(f, "fileRead", { file = true })
			local s = f.data:sub(f.pos + 1, f.pos + n)
			f.pos = f.pos + #s
			return s
		end
		N.fileWrite = function(f, ...)
			el(f, "fileWrite", { file = true })
			if f.readonly or not f.writing then return false end
			local s = table.concat({ ... })
			if m.fail.fileWrite then s = s:sub(1, math.floor(#s / 2)) end
			f.data = f.data .. s
			m.fs[side.name][f.path] = f.data
			return #s
		end
		N.fileClose = function(f)
			el(f, "fileClose", { file = true })
			m.open_files = m.open_files - 1
			m:destroy_element(f)
			return true
		end
		N.fileDelete = function(path) if visible(path) then m.fs[side.name][path] = false; return true end return false end

		-- ------------------------------------------------------------------------------------------------------------ SQLite (server): just the statements server/store.lua uses
		m.fs.db = m.fs.db or {}
		N.dbConnect = function(kind, path)
			if kind ~= "sqlite" then return false end
			return m:new_element("db-connection", { path = path, mine = true }, m.resourceRoot)
		end
		N.dbExec = function(conn, query, ...)
			count("dbExec")
			el(conn, "dbExec", { ["db-connection"] = true })
			if m.fail.dbExec then return false end
			local a, b = ...
			if query:match("^CREATE TABLE IF NOT EXISTS kv") then return true end
			if query:match("^INSERT OR REPLACE INTO kv %(k, v%) VALUES %(%?, %?%)$") then m.fs.db[a] = b; return true end
			if query:match("^DELETE FROM kv WHERE k = %?$") then m.fs.db[a] = nil; return true end
			error("mock: unsupported SQL: " .. query)
		end
		N.dbQuery = function(conn, query, ...)
			el(conn, "dbQuery", { ["db-connection"] = true })
			if not query:match("^SELECT v FROM kv WHERE k = %?$") then error("mock: unsupported SQL: " .. query) end
			local key = ...
			return { __query = true, rows = (m.fs.db[key] ~= nil) and { { v = m.fs.db[key] } } or {} }
		end
		N.dbPoll = function(q, timeout) if type(q) == "table" and q.__query then return q.rows end return false end

		-- ------------------------------------------------------------------------------------------------------------ client: screen, cursor, input, camera, drawing
		if is_client then
			env.localPlayer = m.player
			env.guiRoot = m:new_element("gui-root", {}, m.root)
		end
		env.root, env.resource, env.resourceRoot, env.resourceName = m.root, m.resource, m.resourceRoot, "outbreak"
		N.guiGetScreenSize = function() return m.screen.w, m.screen.h end
		N.tocolor = function(r, g, b, a) return ((a or 255) * 16777216) + (r * 65536) + (g * 256) + b end
		N.dxDrawLine3D = function() m.dx.lines = m.dx.lines + 1; return true end
		N.dxDrawRectangle = function() m.dx.rects = m.dx.rects + 1; return true end
		N.dxDrawImage = function() m.dx.images = m.dx.images + 1; return true end
		N.showCursor = function(show)
			if is_client then m.cursor.showing = show and true or false; return true end
			return true
		end
		N.isCursorShowing = function() return m.cursor.showing end
		N.getCursorPosition = function() if not m.cursor.showing then return false end return m.cursor.x, m.cursor.y end
		N.guiSetInputMode = function(mode)
			if mode ~= "allow_binds" and mode ~= "no_binds" and mode ~= "no_binds_when_editing" then return false end
			m.input.mode = mode
			return true
		end
		N.toggleAllControls = function(enabled) m.input.all_controls = enabled and true or false; return true end
		N.toggleControl = function(name, enabled) m.input.controls[name] = enabled and true or false; return true end
		N.getControlState = function(name) return m.player_control[name] == true end
		N.bindKey = function(key, state, fn, ...)
			count("bindKey")
			if type(key) ~= "string" or key ~= key:lower() then error("mock: MTA key names are lower case: " .. tostring(key), 2) end
			m.binds[#m.binds + 1] = { key = key, state = state, fn = fn, args = { ... } }
			return true
		end
		N.setPlayerHudComponentVisible = function(name, show) m.hud[name] = show and true or false; return true end
		N.playSoundFrontEnd = function(id) m.sound[#m.sound + 1] = id; return true end
		N.getVehicleSirensOn = function(v) return m.vehicle_state and m.vehicle_state.siren or false end
		N.setCameraMatrix = function(x, y, z, lx, ly, lz, roll, fov)
			if not is_client then error("mock: the server variant of setCameraMatrix takes a player first", 2) end
			if type(x) ~= "number" then error("Bad argument @ 'setCameraMatrix'", 2) end
			local c = m.cam
			c.x, c.y, c.z, c.lx, c.ly, c.lz, c.fov, c.matrix_set, c.target = x, y, z, lx or c.lx, ly or c.ly, lz or c.lz, fov or 70, true, nil
			c.sets = (c.sets or 0) + 1
			return true
		end
		N.setCameraTarget = function(a, b)
			if is_client then m.cam.target = a; m.cam.matrix_set = false; return true end
			m.cam.target = b; m.cam.matrix_set = false; return true
		end
		N.getCameraMatrix = function()
			local c = m.cam
			if c.matrix_set then return c.x, c.y, c.z, c.lx, c.ly, c.lz, 0.0, c.fov end
			local p = m.player
			return p.x, p.y - 4.0, p.z + 2.0, p.x, p.y, p.z, 0.0, 70.0
		end
		local function cam_dir(px, py)
			local Ray = m:raymath()
			local c = m.cam
			local pitch, yaw = Ray.look_at(c.x, c.y, c.z, c.lx, c.ly, c.lz)
			return Ray.screen_ray(pitch, yaw, c.fov, m.screen.w / m.screen.h, px / m.screen.w, py / m.screen.h)
		end
		N.getWorldFromScreenPosition = function(px, py, depth)
			if not m.cam.matrix_set then return false end
			local dx, dy, dz = cam_dir(px, py)
			local c = m.cam
			return c.x + dx * depth, c.y + dy * depth, c.z + dz * depth
		end
		N.getScreenFromWorldPosition = function(x, y, z)
			if not m.cam.matrix_set then return false end
			local Ray = m:raymath()
			local c = m.cam
			local pitch, yaw = Ray.look_at(c.x, c.y, c.z, c.lx, c.ly, c.lz)
			local sx, sy, depth = Ray.project(c.x, c.y, c.z, pitch, yaw, c.fov, m.screen.w / m.screen.h, x, y, z)
			if not sx then return false end
			return sx * m.screen.w, sy * m.screen.h, depth
		end
		N.getGroundPosition = function(x, y, z)
			if m.no_ground then return 0.0 end
			return terrain(x, y)
		end
		N.processLineOfSight = function(x1, y1, z1, x2, y2, z2)
			local len = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2 + (z2 - z1) ^ 2)
			local steps = math.max(1, math.floor(len))
			for i = 1, steps do
				local t = i / steps
				local px, py, pz = x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, z1 + (z2 - z1) * t
				if pz <= terrain(px, py) then return true, px, py, terrain(px, py), nil end
			end
			return false
		end

		-- ------------------------------------------------------------------------------------------------------------ client: the CEF browser
		local function make_browser(w, h, is_local, transparent)
			local b = m:new_element("webbrowser", { mine = true, created_by = "client", is_local = is_local, transparent = transparent, created = false, ready = false, loading = false, paused = false, url = nil,
				w = w, h = h, mouse = {} }, m.resourceRoot)
			m.browser = b
			m.browsers = m.browsers or {}
			m.browsers[#m.browsers + 1] = b
			-- the browser initialises asynchronously: onClientBrowserCreated fires a moment later
			side.timers_extra = side.timers_extra or {}
			local due = m.t + (m.browser_create_ms or 100)
			m.deferred = m.deferred or {}
			m.deferred[#m.deferred + 1] = { due = due, fn = function()
				if b.destroyed then return end
				b.created = true
				m:trigger(side, "onClientBrowserCreated", b)
			end }
			return b
		end
		N.createBrowser = function(w, h, is_local, transparent)
			count("createBrowser")
			if type(w) ~= "number" or w < 1 or h < 1 then error("Bad argument @ 'createBrowser' [size must be at least 1]", 2) end
			if m.fail.createBrowser then return false end
			return make_browser(w, h, is_local, transparent)
		end
		N.guiCreateBrowser = function(x, y, w, h, is_local, transparent, relative, parent)
			count("guiCreateBrowser")
			if w < 1 and not relative or h < 1 and not relative then error("Bad argument @ 'guiCreateBrowser' [size must be at least 1]", 2) end
			if relative and (x < 0 or x > 1 or y < 0 or y > 1 or w < 0 or w > 1 or h < 0 or h > 1) then error("Bad argument @ 'guiCreateBrowser' [relative values must be 0..1]", 2) end
			if m.fail.createBrowser then return false end
			local g = m:new_element("gui-browser", { mine = true, created_by = "client" }, m.resourceRoot)
			g.browser = make_browser(w, h, is_local, transparent)
			return g
		end
		N.guiGetBrowser = function(g) return el(g, "guiGetBrowser", { ["gui-browser"] = true }).browser end
		N.loadBrowserURL = function(b, url)
			count("loadBrowserURL")
			el(b, "loadBrowserURL", { webbrowser = true })
			if not b.created then m.errors[#m.errors + 1] = "loadBrowserURL called before onClientBrowserCreated"; return false end
			b.url, b.loading, b.ready = url, true, false
			m.deferred = m.deferred or {}
			m.deferred[#m.deferred + 1] = { due = m.t + (m.browser_load_ms or 100), fn = function()
				if b.destroyed then return end
				b.loading, b.ready = false, true
				m:trigger(side, "onClientBrowserDocumentReady", b, url)
			end }
			return true
		end
		N.executeBrowserJavascript = function(b, js)
			count("executeBrowserJavascript")
			el(b, "executeBrowserJavascript", { webbrowser = true })
			if not b.is_local then return false end
			if not b.ready then m.errors[#m.errors + 1] = "executeBrowserJavascript before the document was ready"; return false end
			m.browser_js[#m.browser_js + 1] = js
			if #m.browser_js > 5000 then table.remove(m.browser_js, 1) end
			local body = js:match("^window%.dispatchEvent%(new MessageEvent%('message',{data:(.*)}%)%)$")
			if not body then m.errors[#m.errors + 1] = "unexpected JavaScript pushed into the page: " .. js:sub(1, 80); return true end
			local ok, msg = pcall(m:json_decode().decode, body, { max_len = 4000000, max_depth = 40 })
			if not ok or type(msg) ~= "table" then m.errors[#m.errors + 1] = "the page message is not valid JSON: " .. tostring(msg); return true end
			m.browser_msgs[#m.browser_msgs + 1] = msg
			if #m.browser_msgs > 4000 then table.remove(m.browser_msgs, 1) end
			return true
		end
		N.focusBrowser = function(b) if b ~= nil then el(b, "focusBrowser", { webbrowser = true }) end m.input.focused_browser = b; return true end
		N.isBrowserFocused = function(b) return m.input.focused_browser == b end
		N.setBrowserRenderingPaused = function(b, p) el(b, "setBrowserRenderingPaused", { webbrowser = true }).paused = p and true or false; return true end
		N.isBrowserDomainBlocked = function(url, parse) return not (type(url) == "string" and url:find("^http://mta/local/")) end
		N.requestBrowserDomains = function(list, parse, cb)
			m.requested_domains = list
			if cb then cb(true, list) end
			return true
		end
		N.injectBrowserMouseMove = function(b, x, y) el(b, "injectBrowserMouseMove", { webbrowser = true }).mouse.move = { x = x, y = y }; return true end
		N.injectBrowserMouseDown = function(b, button) el(b, "injectBrowserMouseDown", { webbrowser = true }).mouse.down = button; return true end
		N.injectBrowserMouseUp = function(b, button) el(b, "injectBrowserMouseUp", { webbrowser = true }).mouse.up = button; return true end
		N.injectBrowserMouseWheel = function(b, v, h) el(b, "injectBrowserMouseWheel", { webbrowser = true }).mouse.wheel = v; return true end

		-- ------------------------------------------------------------------------------------------------------------ install: only what exists on this side in the REAL source
		m.unexposed = m.unexposed or {}
		for name, fn in pairs(N) do
			local real = (not m.defs) or (is_client and m.defs.client[name]) or (not is_client and m.defs.server[name])
			if real then
				env[name] = function(...) count(name); return fn(...) end
			else
				m.unexposed[side.name .. ":" .. name] = true
			end
		end
		-- built-in events of this side (from the real CClientGame.cpp / CGame.cpp)
		if m.defs then
			for ev in pairs(is_client and m.defs.events.client or m.defs.events.server) do side.events[ev] = { remote = false, builtin = true } end
		end
		side.events["onClientBrowserCreated"] = side.events["onClientBrowserCreated"] or { remote = false, builtin = true }
	end

	-- a ped died (health 0 or killPed): fire the server's onPedWasted / onPlayerWasted
	function Mock:wasted(e, killer, weapon, bodypart, stealth)
		if e.dead then return end
		e.dead, e.health, e.killer = true, 0, killer
		e.controls = {}
		local srv = self.sides.server
		if srv and srv.started then
			if e.type == "player" then self:trigger(srv, "onPlayerWasted", e, 0, killer, weapon, bodypart, stealth)
			else self:trigger(srv, "onPedWasted", e, 0, killer, weapon, bodypart, stealth) end
		end
		local cl = self.sides.client
		if cl and cl.started then self:trigger(cl, e.type == "player" and "onClientPlayerWasted" or "onClientPedWasted", e, killer, weapon, bodypart) end
	end

	function Mock:raymath()
		if self._ray then return self._ray end
		local f = assert((loadstring or load)(assert(io.open(self.root_dir .. "/shared/raymath.lua", "rb")):read("*a"), "@shared/raymath.lua"))
		self._ray = f()
		return self._ray
	end

	-- ---------------------------------------------------------------------------------------------------------------- physics step
	local SPEED = { walk = 1.4, jog = 3.6, sprint = 6.0 }
	function Mock:physics(dt)
		local sec = dt / 1000
		-- deferred browser work (creation / page load)
		if self.deferred and #self.deferred > 0 then
			local list = self.deferred
			self.deferred = {}
			for _, d in ipairs(list) do if d.due <= self.t then d.fn() else self.deferred[#self.deferred + 1] = d end end
		end
		for _, e in pairs(self.els) do
			if e.type == "ped" and not e.destroyed and not e.dead and e.mine then
				local streamed = self.player and dist2(e, self.player) <= STREAM
				local syncer_ok
				if e.syncer ~= nil then syncer_ok = (e.syncer == self.player) else syncer_ok = self.auto_syncer ~= false end
				if streamed and syncer_ok and not e.frozen then
					local gz = terrain(e.x, e.y)
					if e.z < gz - 3.0 then e.fell, e.z = true, -50.0
					elseif not e.fell then e.z = (e.z > gz + 1.05) and math.max(gz + 1.0, e.z - 9.8 * sec) or (gz + 1.0) end
					if e.controls.forwards and not e.fell then
						local v = (e.controls.sprint and SPEED.sprint) or (e.controls.walk and SPEED.walk) or SPEED.jog
						local r = math.rad(e.rz)
						local nx, ny = e.x + (-math.sin(r)) * v * sec, e.y + math.cos(r) * v * sec
						local blocked = false
						for _, w in ipairs(self.walls or {}) do
							if nx >= w[1] and nx <= w[3] and ny >= w[2] and ny <= w[4] then blocked = true; break end
						end
						if blocked then e.blocked_ms = (e.blocked_ms or 0) + dt else e.x, e.y = nx, ny; e.blocked_ms = 0; e.walked = (e.walked or 0) + v * sec end
						e.vx, e.vy = (nx - e.x), (ny - e.y)
					end
				end
			end
		end
	end

	-- ---------------------------------------------------------------------------------------------------------------- scripted gameplay helpers for tests
	function Mock:player_move_to(x, y) local p = self.player; p.x, p.y, p.z = x, y, terrain(x, y) + 1.0 end
	function Mock:damage_ped(e, amount, killer)
		e.health = e.health - amount
		if e.health <= 0 then self:wasted(e, killer, 22, 3, false) end
	end
	function Mock:player_fire(weapon)
		local cl = self.sides.client
		self:trigger(cl, "onClientPlayerWeaponFire", self.player, weapon, 10, 10, 0, 0, 0, nil)
	end
	function Mock:ped_fire(ped, weapon)
		local cl = self.sides.client
		self:trigger(cl, "onClientPedWeaponFire", ped, weapon, 10, 10, 0, 0, 0, nil)
	end
	function Mock:explosion(x, y, z)
		self:trigger(self.sides.client, "onClientExplosion", self.root, x, y, z, 4)
	end
	function Mock:damage_player(loss, weapon)
		local cl = self.sides.client
		return self:trigger(cl, "onClientPlayerDamage", self.player, nil, weapon or 54, 3, loss)
	end
end
