-- server/commands.lua : the /outbreak_* admin and debug commands (addCommandHandler). A command is allowed for the server console, for the colony owner when the owner_admin setting is on,
-- and for any player whose ACL group has the right command.<name> (see README "ACL"). They are registered unrestricted at the engine level (restricted = false) so the owner shortcut
-- works; the check below is the only gate. Written here (the FiveM adapter's command list on MTA functions). Nothing borrowed.
local ctx = require("server.ctx")
local Zombies = require("server.zombies")
local Raiders = require("server.raiders")
local Colonists = require("server.colonists")
local Peds = require("server.peds")
local Buildings = require("server.buildings")
local Ground = require("server.ground")
local Selftest = require("shared.selftest")
local Phone = require("server.phone")

local Cmd = { list = {}, stats = { run = 0, denied = 0, failed = 0 } }

local function reply(player, text)
	if player and isElement(player) and getElementType(player) == "player" then outputChatBox("[outbreak] " .. text, player)
	else outputServerLog("[outbreak] " .. text) end
end

local function allowed(player, name)
	if not player or not isElement(player) then return true end
	if getElementType(player) == "console" then return true end
	if ctx.scfg.owner_admin and player == ctx.owner then return true end
	return hasObjectPermissionTo(player, "command." .. name, false) and true or false
end

local function command(name, help, fn)
	Cmd.list[#Cmd.list + 1] = { name = name, help = help }
	addCommandHandler(name, function(player, _, a1, a2, a3)
		if not allowed(player, name) then
			Cmd.stats.denied = Cmd.stats.denied + 1
			reply(player, "not allowed (give the player's ACL group the right command." .. name .. ", or use the server console)")
			return
		end
		Cmd.stats.run = Cmd.stats.run + 1
		local ok, err = pcall(fn, player, { a1, a2, a3 })
		if not ok then Cmd.stats.failed = Cmd.stats.failed + 1; reply(player, name .. " failed: " .. tostring(err)) end
	end, false)
end

-- fast-forward in slices: MTA aborts a script that runs for more than a few seconds without returning, so a 40-day jump is spread over timers (120 sim minutes per slice)
local ff = nil
local function ff_step()
	if not ff or not ctx.host or not ctx.host.world then ff = nil; return end
	local chunk = math.min(120, ff.left)
	local ok, n = ctx.host:debug("fast_forward", { minutes = chunk })
	ff.left = ff.left - (ok and chunk or ff.left)
	if ff.left > 0 and ctx.running and not ctx.host.world.s.over then
		ctx.after(50, ff_step)
	else
		reply(ff.player, string.format("fast-forward done (%d minutes)", ff.total - ff.left))
		ff = nil
	end
end

function Cmd.register()
	local function host() return ctx.host end

	command("outbreak_status", "show the colony status", function(p)
		local st = host():status()
		if not st.world then return reply(p, "no world") end
		reply(p, string.format("%s day %d seed %d %s | colonists %d hordes %d (live %d) raids %d buildings %d | speed %s scale %.0f | hash %s | owner %s",
			st.time, st.day, st.seed, st.profile, st.colonists, st.hordes, st.materialized, st.raids, st.buildings, st.paused and "paused" or tostring(st.speed), st.scale, st.hash,
			ctx.owner and getPlayerName(ctx.owner) or "none"))
	end)
	command("outbreak_save", "save now", function(p) local ok, why = host():save_game("command"); reply(p, ok and ("saved to slot " .. tostring(why)) or ("save failed: " .. tostring(why))) end)
	command("outbreak_load", "load the latest save", function(p) local ok, why = host():load_game(); reply(p, ok and ("loaded slot " .. tostring(why)) or ("load failed: " .. tostring(why))) end)
	command("outbreak_new", "outbreak_new [seed] [calm|escalating|chaos]", function(p, a) reply(p, tostring(host():new_game(tonumber(a[1]), a[2], nil))) end)
	command("outbreak_pause", "toggle the clock", function(p) host():ui_action("toggle_pause", {}); reply(p, host().paused and "paused" or "running") end)
	command("outbreak_speed", "outbreak_speed 0|1|2|4|8|16", function(p, a) reply(p, tostring(host():ui_action("set_speed", { speed = tonumber(a[1]) }))) end)
	command("outbreak_profile", "outbreak_profile calm|escalating|chaos", function(p, a) host():on_order({ id = "colony", kind = "set_profile", target = a[1] }); reply(p, "profile requested: " .. tostring(a[1])) end)
	command("outbreak_horde", "outbreak_horde [size] [distance]", function(p, a) local ok, r = host():debug("horde", { n = tonumber(a[1]) or 20, dist = tonumber(a[2]) or 200 }); reply(p, tostring(ok) .. " " .. tostring(r)) end)
	command("outbreak_event", "outbreak_event <director event id>", function(p, a) local ok, r = host():debug("event", { id = a[1] }); reply(p, tostring(ok) .. " " .. tostring(r)) end)
	command("outbreak_give", "outbreak_give <item id> [n]", function(p, a) local ok, r = host():debug("give", { item = a[1], n = tonumber(a[2]) or 1 }); reply(p, tostring(ok) .. " " .. tostring(r or "")) end)
	command("outbreak_day", "outbreak_day <hour> [minute] [day]", function(p, a) local ok = host():debug("time_set", { hour = tonumber(a[1]) or 12, minute = tonumber(a[2]) or 0, day = tonumber(a[3]) }); reply(p, tostring(ok)) end)
	command("outbreak_autopilot", "outbreak_autopilot on|off (the sim's own AI plays the colony)", function(p, a) local _, on = host():debug("autopilot", { on = a[1] ~= "off" }); reply(p, "autopilot " .. tostring(on)) end)
	command("outbreak_ff", "outbreak_ff <minutes>  fast-forward the sim", function(p, a)
		if ff then return reply(p, "a fast-forward is already running") end
		local minutes = math.max(1, math.min(60 * 24 * 40, math.floor(tonumber(a[1]) or 60)))
		ff = { left = minutes, total = minutes, player = p }
		ff_step()
	end)
	-- a server-side getter for the phone e2e (tools/phone_e2e.sh) and for you: what the SIM holds, independent of any page. `outbreak_prio c1` lists every work priority of c1,
	-- `outbreak_prio c1 cook` one of them. A priority set from a phone (order priority) shows up here.
	command("outbreak_prio", "outbreak_prio <colonist id> [work]  print the work priorities the sim holds", function(p, a)
		local w = host().world
		local c = w and a[1] and w:colonist(a[1])
		if not c then return reply(p, "no such colonist: " .. tostring(a[1])) end
		local colonist = require("sim.colonist")
		local out = {}
		for _, wt in ipairs(colonist.WORK) do if not a[2] or a[2] == wt then out[#out + 1] = wt .. "=" .. tostring(colonist.priority(c, wt)) end end
		reply(p, "prio " .. c.id .. " " .. table.concat(out, " "))
	end)
	command("outbreak_phone", "phone companion status: sessions, calls, refusals", function(p) reply(p, Phone.describe()) end)
	command("outbreak_hash", "print the sim state hash", function(p) reply(p, host().world and host().world:hash() or "no world") end)
	command("outbreak_audit", "item conservation check", function(p) local ok, rep = host():debug("audit", {}); reply(p, ok and "audit OK" or ("audit FAILED: " .. table.concat(rep.problems or {}, "; "))) end)
	command("outbreak_peds", "ped / object budget and counters", function(p)
		local ps = Peds.stats
		reply(p, string.format("peds %d/%d (pool guard %d, ped elements %d) zombies %d pending %d raiders %d colonists %d | objects %d/%d | created %d refused cap %d pool %d | ground samples %d reseated %d | syncers %d",
			Peds.n, ctx.cfg.max_peds, ctx.cfg.pool_guard, #getElementsByType("ped"), Zombies.alive_total(), Zombies.pending_total(), Raiders.alive_total(), Colonists.ped_count(),
			Buildings.count(), ctx.cfg.max_objects, ps.created, ps.refused_cap, ps.refused_pool, Ground.stats.samples, Ground.stats.reseated, Peds.syncer_count()))
	end)
	-- a test hook, not gameplay: a real server with no client connected has no observer, so the sim never materializes a horde there and the ped code would go unexercised. This creates
	-- zombies around the base through the real spawn path (caps, pool guard, model check) and reads back from the ENGINE what it made: model, tag, syncer
	command("outbreak_spawn", "outbreak_spawn [n] [walker|runner|brute|screamer]  create n test zombies at the base (never more than max_materialized hostile peds)", function(p, a)
		local n = math.max(1, math.min(200, math.floor(tonumber(a[1]) or 10)))
		local room = math.max(0, ctx.scfg.max_materialized - (Zombies.alive_total() + Raiders.alive_total()))
		local made, refused = Zombies.debug_spawn(math.min(n, room), a[2])
		local models = {}
		for _, id in ipairs(ctx.cfg.zombie_models) do models[id] = true end
		for _, id in ipairs(ctx.cfg.brute_models) do models[id] = true end
		local all, model_ok, tagged, no_syncer, health_ok = 0, 0, 0, 0, 0
		for ped, rec in pairs(Peds.list) do
			if rec.kind == "zombie" and rec.tag == "debug" and isElement(ped) then
				all = all + 1
				if models[getElementModel(ped)] then model_ok = model_ok + 1 end
				if getElementData(ped, "ob") == "zombie" then tagged = tagged + 1 end
				if not isElement(getElementSyncer(ped)) then no_syncer = no_syncer + 1 end
				if getElementHealth(ped) > 0 then health_ok = health_ok + 1 end
			end
		end
		reply(p, string.format("spawned %d of %d requested (%s): test zombies %d | models in config %d/%d, tagged %d/%d, alive %d/%d, syncer-less %d/%d | hostile peds %d of %d | ped elements %d",
			made, n, refused or ((made < n) and "hostile cap" or "ok"), all, model_ok, all, tagged, all, health_ok, all, no_syncer, all,
			Zombies.alive_total() + Raiders.alive_total(), ctx.scfg.max_materialized, #getElementsByType("ped")))
	end)
	command("outbreak_selftest", "rerun the Lua determinism self-test", function(p)
		local ok, r = Selftest.check()
		reply(p, string.format("selftest %s: hash %s expected %s reload %s (%s ms)%s", ok and "OK" or "FAILED", tostring(r.hash), tostring(r.expected), tostring(r.reload_ok), tostring(r.ms), r.error and (" error: " .. r.error) or ""))
	end)
end

function Cmd.cancel_ff() ff = nil end

return Cmd
