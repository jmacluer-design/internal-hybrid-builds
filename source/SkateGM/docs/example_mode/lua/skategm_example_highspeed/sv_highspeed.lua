local mode = HIGHSPEED.mode
local game = { phase = "idle", best = {} }

local function Public()
	local list = {}
	for ply, speed in pairs(game.best) do
		if IsValid(ply) then list[#list + 1] = { name = ply:Nick(), speed = math.floor(speed * 10) / 10 } end
	end
	table.sort(list, function(a, b) return a.speed > b.speed end)
	return { phase = game.phase, left = game.endsAt and math.max(0, game.endsAt - CurTime()) or 0, top = list }
end

mode:OnCommand(function(ply, m)
	if not mode:Allowed() then return end
	if m.cmd == "start" and game.phase == "idle" then
		game.phase, game.best, game.endsAt = "on", {}, CurTime() + HIGHSPEED.DURATION
		mode:Broadcast(Public())
	elseif m.cmd == "speed" and game.phase == "on" then
		local v = math.Clamp(tonumber(m.v) or 0, 0, 200)
		if v > (game.best[ply] or 0) then game.best[ply] = v end
	end
end)

mode:OnThink(function(now)
	if game.phase ~= "on" then return end
	if now >= game.endsAt then game.phase = "idle" end
	if now - (mode.lastBroadcast or 0) >= 0.5 or game.phase == "idle" then mode:Broadcast(Public(), now) end
end)

mode:OnPlayerJoin(function(ply) if game.phase == "on" then mode:SendState(ply, Public()) end end)
mode:OnPlayerLeave(function(ply) game.best[ply] = nil end)
mode:OnDisallowed(function() game.phase = "idle" mode:Broadcast(Public()) end)
