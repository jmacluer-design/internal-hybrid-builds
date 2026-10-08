-- Own the Spot, server: the session. Uses only SkateGM.API from the skating add-on.

local S = { phase = "idle" }
OTS.session = S
OTS.mode:UseSessions(S)

local API, Allowed, Skating = SKATEGM_MODES.API, SKATEGM_MODES.Allowed, SKATEGM_MODES.Skating

local function Tell(ply, text) OTS.mode:Tell(ply, text) end

local function Key(ply) return SKATEGM_MODES.Key(ply) end
local function IndexOf(ply) return SKATEGM_MODES.IndexOf(S.players, ply) end

---------------------------------------------------------------------------
-- what every client sees
---------------------------------------------------------------------------
local function Public(now)
	local t = { phase = S.phase }
	if S.phase == "idle" then return t end
	t.host = IsValid(S.host) and S.host:EntIndex() or 0
	t.spot = { S.spot.x, S.spot.y, S.spot.z }
	t.yaw, t.turn, t.rounds, t.round, t.index = S.yaw, S.turn, S.rounds, S.round, S.index
	t.active = IsValid(S.active) and S.active:EntIndex() or 0
	t.timeLeft = S.deadline and math.max(0, S.deadline - now) or 0
	t.live = S.live or 0
	t.last = S.last
	t.winner = S.winner
	t.players = {}
	for _, p in ipairs(S.players) do
		local e = S.entries[Key(p)]
		t.players[#t.players + 1] = { ent = p:EntIndex(), name = p:Nick(), best = e.best, total = e.total, turns = #e.turns }
	end
	-- people who left keep their result in the standings
	t.gone = {}
	for key, e in pairs(S.entries) do
		if e.left then t.gone[#t.gone + 1] = { name = e.name, best = e.best, total = e.total } end
	end
	return t
end

local function Broadcast(now)
	OTS.mode:Broadcast(Public(now or CurTime()), now)
	S.lastBroadcast = now or CurTime()
end
OTS.Broadcast = Broadcast

-- everyone taking part but the active player stays put while they watch
local function Freezes()
	for _, p in ipairs(S.players or {}) do
		if IsValid(p) then p:Freeze(S.phase ~= "lobby" and S.phase ~= "final" and p ~= S.active) end
	end
end

---------------------------------------------------------------------------
-- flow
---------------------------------------------------------------------------
local StartTurn, NextTurn, EndTurn

local function Stop(reason, now)
	for _, p in ipairs(S.players or {}) do if IsValid(p) then p:Freeze(false) end end
	for k in pairs(S) do S[k] = nil end
	S.phase = "idle"
	Broadcast(now)
	if reason then Tell(nil, reason) end
end
OTS.Stop = Stop

local function Final(now)
	S.phase, S.active, S.deadline = "final", nil, now + OTS.FINAL
	local best, who = -1, nil
	for _, e in pairs(S.entries) do
		if #e.turns > 0 and e.best > best then best, who = e.best, e.name end
	end
	S.winner = who and { name = who, score = best } or nil
	Freezes()
	Broadcast(now)
	if who then Tell(nil, string.format("%s owns the spot with %s!", who, string.Comma(math.floor(best)))) else Tell(nil, "nobody set a score") end
end

function StartTurn(now)
	local p = S.players[S.index]
	if not IsValid(p) then return NextTurn(now) end
	S.phase, S.active, S.live, S.deadline = "prep", p, 0, now + OTS.PREP_TIMEOUT
	S.offSince = nil
	Freezes()
	Broadcast(now)
end

function NextTurn(now)
	if #S.players == 0 then return Stop("everyone left: the challenge is over", now) end
	S.index = S.index + 1
	if S.index > #S.players then
		S.index = 1
		S.round = S.round + 1
		if S.round > S.rounds then return Final(now) end
	end
	StartTurn(now)
end

-- record the active player's turn (unless they never got going)
function EndTurn(now, reason, record)
	local p = S.active
	if record and IsValid(p) then
		local e = S.entries[Key(p)]
		local score = math.Clamp(math.floor(S.live or 0), 0, OTS.MAX_SCORE)
		e.turns[#e.turns + 1] = score
		e.best = math.max(e.best, score)
		e.total = e.total + score
		S.last = { name = p:Nick(), score = score, reason = reason }
		S.lastKey = Key(p)
	else
		S.last = { name = IsValid(p) and p:Nick() or "?", score = 0, reason = reason, skipped = true }
		S.lastKey = nil
	end
	S.phase, S.deadline = "between", now + OTS.BETWEEN
	S.active = nil
	Freezes()
	Broadcast(now)
end

-- a late final score from the player whose turn just ended replaces the last live one
local function LateFinal(ply, score, now)
	if S.phase ~= "between" or not S.lastKey or S.lastKey ~= Key(ply) then return end
	local e = S.entries[S.lastKey]
	score = math.Clamp(math.floor(score or 0), 0, OTS.MAX_SCORE)
	local old = e.turns[#e.turns]
	e.turns[#e.turns] = score
	e.total = e.total - old + score
	e.best = 0
	for _, v in ipairs(e.turns) do e.best = math.max(e.best, v) end
	S.last.score = score
	S.lastKey = nil
	Broadcast(now)
end

function OTS.Tick(now)
	local ph = S.phase
	if ph == "idle" or ph == "lobby" then return end
	if ph == "prep" and now > S.deadline then
		Tell(nil, (IsValid(S.active) and S.active:Nick() or "?") .. " couldn't get into Skater mode in time: skipped")
		EndTurn(now, "couldn't start", false)
	elseif ph == "countdown" and now > S.deadline then
		S.phase, S.deadline, S.live = "turn", now + S.turn, 0
		Broadcast(now)
	elseif ph == "turn" then
		-- leaving Skater mode ends the turn (a second of grace for hiccups)
		if not Skating(S.active) then
			S.offSince = S.offSince or now
			if now - S.offSince > 1 then return EndTurn(now, "left Skater mode", true) end
		else
			S.offSince = nil
		end
		if now > S.deadline then return EndTurn(now, "time", true) end
		if now - (S.lastBroadcast or 0) > 0.5 then Broadcast(now) end
	elseif ph == "between" and now > S.deadline then
		NextTurn(now)
	elseif ph == "final" and now > S.deadline then
		Stop(nil, now)
	end
end
OTS.mode:OnThink(function(now) OTS.Tick(now) end)

---------------------------------------------------------------------------
-- players leaving: skipped from then on; the session stops if nobody's left
---------------------------------------------------------------------------
function OTS.Remove(ply, why, now)
	now = now or CurTime()
	local i = IndexOf(ply)
	if not i then return end
	local e = S.entries[Key(ply)]
	if e then e.left = true end
	if IsValid(ply) then ply:Freeze(false) end
	table.remove(S.players, i)
	local wasActive = S.active == ply
	if S.phase ~= "lobby" and S.phase ~= "final" then
		if i < S.index or (i == S.index and wasActive) then S.index = S.index - 1 end
	end
	if #S.players == 0 then return Stop("everyone left: the challenge is over", now) end
	if S.host == ply then
		S.host = S.players[1]
		Tell(nil, S.host:Nick() .. " is the host now")
	end
	Tell(nil, ply:Nick() .. " " .. why)
	if wasActive then
		if S.phase == "prep" then
			S.active = nil
			NextTurn(now)
		else
			-- index already stepped back so the next player comes up next
			S.active = nil
			S.phase, S.deadline = "between", now + 1
			S.last = { name = ply:Nick(), score = 0, reason = why, skipped = true }
			Broadcast(now)
		end
	else
		Broadcast(now)
	end
end
OTS.mode:OnPlayerLeave(function(ply) OTS.Remove(ply, "left the game") end)
hook.Add("PlayerDeath", "skategm_ots", function(ply)
	if S.active == ply and (S.phase == "turn" or S.phase == "countdown") then EndTurn(CurTime(), "died", S.phase == "turn") end
end)

---------------------------------------------------------------------------
-- commands (clients send them; chat and the menu go through the same path)
---------------------------------------------------------------------------
local handlers = {}

function handlers.create(ply, m, now)
	if S.phase ~= "idle" then return Tell(ply, "a challenge is already running") end
	if not Allowed(ply) then return Tell(ply, "you're not allowed to skate on this server") end
	if not m.canSkate then return Tell(ply, "you need Skater mode working (the module and your data) to host") end
	S.phase, S.host = "lobby", ply
	S.spot, S.yaw = ply:GetPos(), ply:EyeAngles().y
	S.turn, S.rounds = OTS.ClampTurn(m.turn), OTS.ClampRounds(m.rounds)
	S.players, S.entries, S.round, S.index = { ply }, {}, 1, 0
	S.entries[Key(ply)] = { name = ply:Nick(), best = 0, total = 0, turns = {} }
	Broadcast(now)
	Tell(nil, ply:Nick() .. " is hosting Own the Spot: join with LB + D-pad left")
end

function handlers.join(ply, m, now)
	if S.phase == "idle" then return Tell(ply, "no challenge is open: !ots create starts one") end
	if S.phase == "final" then return Tell(ply, "this challenge is finishing") end
	if IndexOf(ply) then return end
	if not Allowed(ply) then return Tell(ply, "you're not allowed to skate on this server") end
	if not m.canSkate then return Tell(ply, "you need Skater mode working (the module and your data) to play") end
	S.players[#S.players + 1] = ply
	local e = S.entries[Key(ply)]
	if e then e.left = nil else S.entries[Key(ply)] = { name = ply:Nick(), best = 0, total = 0, turns = {} } end
	Freezes()
	Broadcast(now)
	Tell(nil, ply:Nick() .. " joined" .. (S.phase ~= "lobby" and " (from the next turn in the order)" or ""))
end

function handlers.leave(ply, m, now) OTS.Remove(ply, "left the challenge", now) end

local function Host(ply) return S.phase ~= "idle" and S.host == ply end

function handlers.settings(ply, m, now)
	if not Host(ply) then return Tell(ply, "only the host can change the settings") end
	if S.phase ~= "lobby" then return Tell(ply, "settings can be changed before the start") end
	if m.turn then S.turn = OTS.ClampTurn(m.turn) end
	if m.rounds then S.rounds = OTS.ClampRounds(m.rounds) end
	Broadcast(now)
	Tell(nil, string.format("turns are %d s, %d round%s", S.turn, S.rounds, S.rounds == 1 and "" or "s"))
end

function handlers.spot(ply, m, now)
	if not Host(ply) then return Tell(ply, "only the host can move the spot") end
	if S.phase ~= "lobby" then return Tell(ply, "the spot can be moved before the start") end
	S.spot, S.yaw = ply:GetPos(), ply:EyeAngles().y
	Broadcast(now)
	Tell(nil, "the spot moved to where " .. ply:Nick() .. " is")
end

function handlers.begin(ply, m, now)
	if not Host(ply) then return Tell(ply, "only the host can start") end
	if S.phase ~= "lobby" then return end
	S.round, S.index = 1, 1
	Tell(nil, string.format("Own the Spot is on: %d player%s, %d s turns, %d round%s", #S.players, #S.players == 1 and "" or "s",
		S.turn, S.rounds, S.rounds == 1 and "" or "s"))
	StartTurn(now)
end

function handlers.stop(ply, m, now)
	if S.phase == "idle" then return end
	if not (Host(ply) or ply:IsAdmin()) then return Tell(ply, "only the host or an admin can stop it") end
	Stop("stopped by " .. ply:Nick(), now)
end

-- the active player is at the spot in Skater mode
function handlers.ready(ply, m, now)
	if S.phase ~= "prep" or S.active ~= ply then return end
	S.phase, S.deadline = "countdown", now + OTS.COUNTDOWN
	Broadcast(now)
end

function handlers.live(ply, m, now)
	if S.phase ~= "turn" or S.active ~= ply then return end
	S.live = math.Clamp(tonumber(m.score) or 0, 0, OTS.MAX_SCORE)
end

function handlers.final(ply, m, now) LateFinal(ply, tonumber(m.score), now) end

function OTS.Command(ply, m, now)
	local h = type(m) == "table" and handlers[m.cmd]
	if h and not OTS.Allowed() and m.cmd ~= "leave" then return Tell(ply, "Own the Spot is turned off on this server") end
	if h then h(ply, m, now or CurTime()) end
end

-- turned off mid-session: it ends
OTS.mode:OnDisallowed(function() if S.phase ~= "idle" then OTS.Stop("Own the Spot was turned off on this server") end end)

OTS.mode:OnCommand(function(ply, m) OTS.Command(ply, m) end)

-- someone joining mid-session sees what's going on
OTS.mode:OnPlayerJoin(function(ply)
	if S.phase ~= "idle" then timer.Simple(3, function() if IsValid(ply) then Broadcast() end end) end
end)
