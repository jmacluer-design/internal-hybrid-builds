-- server/phone.lua : the PHONE COMPANION's server half. A phone browser loads the same UI as the in-game page (ui/phone.html, served by MTA's own HTTP server on the HTTP port, default
-- 22005) and talks to this module through ONE exported function, phoneApi (meta.xml <export http="true"/>, reached as POST /<resource>/call/phoneApi with a JSON array body). No GTA client is
-- needed: the sim lives on the server, this module only shows it and takes orders for it.
--
--   what the page gets      exactly the messages the in-game NUI gets (js/main.js routes them): boot, mode, catalog, state (shared/view.lua view model), events (the OUT events of the sim),
--                           inventory / summary answers. `events` come from a ring buffer filled in Net.send (the choke point every OUT message passes), `state` is computed per phone because it
--                           contains the selected colonist's card; a phone's selection never touches the owner's in-game selection.
--   what the page sends     the NUI callbacks: order, ui, place (commit) go to the SAME handlers as the in-game page's remote events (server/net.lua Net.do_order / Net.do_ui, with a token bucket
--                           of their own); ready / mode / screen / focus / mouse / key / close are camera and window business of the in-game client and are acknowledged and ignored.
--   who may                 MTA authenticates (HTTP Basic -> account -> ACL right resource.<res>.http, see README "Phone" and acl.phone.xml); this module then needs the ACL right
--                           resource.<res>.phone_control to give orders and resource.<res>.phone_view to look. Guests, accounts without either right, calls without the X-Outbreak-Phone header
--                           (a custom header cannot be sent cross-site without a CORS preflight the server never answers: CSRF) and calls whose Origin is not the Host are refused.
--   polling                 MTA's call interface answers synchronously (an HTTP request cannot be held open), so the page polls: poll(sid, since, gen) returns the messages after `since` plus a
--                           fresh `state` when it changed. Sessions expire after phone_session_s without a call; more than phone_sessions sessions evict the oldest.
-- Written here (the call-interface and ACL facts are from the MTA source: CResource::HandleRequestCall / IsHttpAccessAllowed, and were checked on the real 1.6 server by tools/phone_e2e.sh).
local ctx = require("server.ctx")
local Net = require("server.net")
local P = require("shared.protocol")
local V = require("shared.view")
local Json = require("shared.json")
local U = require("shared.util")

local MAX_MSGS, MAX_BYTES = 400, 3000000   -- ring buffer: messages kept for slow pollers (beyond that a phone resynchronises with a fresh snapshot)
local STATE_MIN_MS = 400                   -- a state view is never recomputed more often than this (shared by every phone with the same selection)
local MAX_POLLS_PER_SEC = 80               -- all phones together
local SID_PATTERN = "^[%w_%-]+$"

local Phone = {
	enabled = true, generation = 1, seq = 0, first = 1, bytes = 0, ring = {}, sessions = {}, nsessions = 0, catalog_json = nil, state_cache = {}, polls_sec = 0,
	stats = { calls = 0, polls = 0, callbacks = 0, readies = 0, rejected = 0, reasons = {}, orders = 0, ui = 0, captured = 0, dropped = 0, expired = 0, evicted = 0 },
}
local scfg = ctx.scfg

local function reject(why)
	Phone.stats.rejected = Phone.stats.rejected + 1
	Phone.stats.reasons[why] = (Phone.stats.reasons[why] or 0) + 1
	if scfg.debug then ctx.log("warn", "phone call refused: " .. why) end
	return '{"ok":false,"error":' .. Json.encode(why) .. '}'
end

local function resource_name() return getResourceName(getThisResource()) end

-- ---------------------------------------------------------------------------------------------------------------- ring buffer (OUT messages)
local function push(json)
	local seq = Phone.seq + 1
	Phone.seq = seq
	Phone.ring[seq] = json
	Phone.bytes = Phone.bytes + #json
	Phone.stats.captured = Phone.stats.captured + 1
	while (Phone.seq - Phone.first + 1 > MAX_MSGS) or (Phone.bytes > MAX_BYTES and Phone.first < Phone.seq) do
		local old = Phone.ring[Phone.first]
		if old then Phone.bytes = Phone.bytes - #old end
		Phone.ring[Phone.first] = nil
		Phone.first = Phone.first + 1
		Phone.stats.dropped = Phone.stats.dropped + 1
	end
end

-- a new game / a load: every page must start over (ids may repeat, the world is another one)
function Phone.reset()
	Phone.generation = Phone.generation + 1
	Phone.ring, Phone.first, Phone.bytes = {}, Phone.seq + 1, 0
	Phone.catalog_json, Phone.state_cache = nil, {}
end

-- the hook Net.send calls with every OUT message (BEFORE it looks for an owner: a phone works with no GTA client connected)
function Phone.capture(topic, payload)
	if not Phone.enabled or Phone.nsessions == 0 or type(payload) ~= "table" then return end
	if topic ~= P.NET.events then return end -- state is computed per phone; hud / clock / catalog / ui results belong to the in-game owner
	if payload.reset and not ctx.client_only then Phone.reset() end
	local evs = payload.events
	if type(evs) ~= "table" or #evs == 0 then return end
	local ok, json = pcall(Json.encode, { action = "events", data = evs })
	if ok then push(json) else ctx.log("error", "phone: cannot encode events: " .. tostring(json)) end
end

-- ---------------------------------------------------------------------------------------------------------------- identity
local function header(name)
	local h = requestHeaders
	if type(h) ~= "table" then return nil end
	for k, v in pairs(h) do if type(k) == "string" and k:lower() == name then return v end end
	return nil
end

-- the account behind this HTTP request (MTA put it in the global `user`), and what it may do. Returns name, control | nil, reason
local function identity()
	local acc = user
	if not acc then return nil, "no account" end
	if isGuestAccount(acc) then return nil, "guest" end
	local name = getAccountName(acc)
	if type(name) ~= "string" or name == "" then return nil, "no account name" end
	local res = resource_name()
	local obj = "user." .. name
	local control = hasObjectPermissionTo(obj, "resource." .. res .. ".phone_control", false) and true or false
	local view = control or (hasObjectPermissionTo(obj, "resource." .. res .. ".phone_view", false) and true or false)
	if not view then return nil, "no phone right" end
	return name, control
end

-- ---------------------------------------------------------------------------------------------------------------- sessions
local function get_session(sid, name, control, create)
	local s = Phone.sessions[sid]
	if s then
		if s.account ~= name then return nil end -- a session id belongs to the account that made it
		s.control, s.last = control, getTickCount()
		return s
	end
	if not create then return nil end
	if Phone.nsessions >= scfg.phone_sessions then -- evict the least recently used one
		local oldest, oid
		for id, v in pairs(Phone.sessions) do if not oldest or v.last < oldest.last then oldest, oid = v, id end end
		if oid then Phone.sessions[oid] = nil; Phone.nsessions = Phone.nsessions - 1; Phone.stats.evicted = Phone.stats.evicted + 1 end
	end
	s = { account = name, control = control, last = getTickCount(), seq = Phone.seq, sel = nil, other = nil, last_state = nil, made = getTickCount() }
	Phone.sessions[sid] = s
	Phone.nsessions = Phone.nsessions + 1
	return s
end

function Phone.sweep()
	local now = getTickCount()
	local limit = scfg.phone_session_s * 1000
	for id, s in pairs(Phone.sessions) do
		if now - s.last > limit then Phone.sessions[id] = nil; Phone.nsessions = Phone.nsessions - 1; Phone.stats.expired = Phone.stats.expired + 1 end
	end
	Phone.state_cache = {}
	Phone.polls_sec = 0
	if Phone.nsessions == 0 then Phone.ring, Phone.first, Phone.bytes, Phone.seq = {}, Phone.seq + 1, 0, Phone.seq end -- nobody listens: keep nothing
end

-- ---------------------------------------------------------------------------------------------------------------- views
local function boot_json(name, control)
	return Json.encode({ action = "boot", data = { preview = true, phone = true, badge = "LIVE \194\183 MTA SERVER", resource = resource_name(), version = require("shared.mta_config").VERSION,
		role = control and "control" or "view", account = name } })
end

local function catalog_json()
	if not Phone.catalog_json then Phone.catalog_json = Json.encode({ action = "catalog", data = V.catalog() }) end
	return Phone.catalog_json
end

-- the state message for this phone: nil when it did not change since the one it already has (unless force)
local function state_msg(sess, force)
	local host = ctx.host
	local w = host and host.world
	if not w then return nil end
	local now = getTickCount()
	local key = sess.sel or ""
	local c = Phone.state_cache[key]
	if not c or now - c.at >= STATE_MIN_MS then
		local sel = sess.sel
		if sel and not w:colonist(sel) then sel, sess.sel = nil, nil end
		local ok, json = pcall(function()
			return Json.encode({ action = "state", data = V.state(w, { select = sel, speed = host.speed, paused = host.paused or host.speed == 0, scale = host:effective_scale() / 60 }) })
		end)
		if not ok then ctx.log("error", "phone: state view failed: " .. tostring(json)); return nil end
		c = { at = now, json = json }
		Phone.state_cache[key] = c
	end
	if not force and sess.last_state == c.json then return nil end
	sess.last_state = c.json
	return c.json
end

local function envelope(sess, role, msgs, extra)
	return '{"ok":true,"seq":' .. Phone.seq .. ',"gen":' .. Phone.generation .. ',"role":"' .. (role and "control" or "view") .. '"' .. (extra or "") .. ',"msgs":[' .. table.concat(msgs, ",") .. "]}"
end

-- ---------------------------------------------------------------------------------------------------------------- operations
local function op_ready(sid, name, control)
	local sess = get_session(sid, name, control, true)
	if not sess then return reject("session belongs to another account") end
	Phone.stats.readies = Phone.stats.readies + 1
	sess.seq, sess.sel, sess.other, sess.last_state = Phone.seq, nil, nil, nil
	local msgs = { boot_json(name, control), Json.encode({ action = "mode", data = { mode = "colony" } }), catalog_json() }
	local st = state_msg(sess, true)
	if st then msgs[#msgs + 1] = st end
	return envelope(sess, control, msgs)
end

local function op_poll(sess, control, since, gen)
	Phone.stats.polls = Phone.stats.polls + 1
	if tonumber(gen) ~= Phone.generation then return '{"ok":true,"resync":true}' end
	since = tonumber(since)
	if not since or since < Phone.first - 1 or since > Phone.seq then return '{"ok":true,"resync":true}' end
	local msgs = {}
	for s = since + 1, Phone.seq do msgs[#msgs + 1] = Phone.ring[s] end
	local st = state_msg(sess, false)
	if st then msgs[#msgs + 1] = st end
	sess.seq = Phone.seq
	return envelope(sess, control, msgs)
end

local function loc(v) -- the host's own container spec check (shared/host.lua loc)
	if type(v) ~= "table" then return nil end
	local kind, id = v.kind, v.id
	if (kind == "zone" or kind == "pile" or kind == "colonist" or kind == "container") and type(id) == "string" and #id <= 64 then return { kind = kind, id = id } end
	return nil
end

local READ_ONLY = { select = true, inventory = true, request_summary = true, request_state = true, request_catalog = true, screens = true }
local MUTATING_INVENTORY = { inventory_move = true, use_item = true, drop_item = true }
local IGNORED = { ready = true, mode = true, screen = true, focus = true, mouse = true, key = true, close = true } -- the in-game client's camera and window business

local function inventory_msg(sess)
	return Json.encode({ action = "inventory", data = V.inventory(ctx.host.world, { other = sess.other }) })
end

local function op_cb(sess, control, account, name, data)
	Phone.stats.callbacks = Phone.stats.callbacks + 1
	if type(name) ~= "string" or #name > 24 then return reject("bad callback name") end
	if data ~= nil and type(data) ~= "table" then return reject("bad callback data") end
	data = data or {}
	local host = ctx.host
	if IGNORED[name] then return envelope(sess, control, {}) end
	if not host or not host.world then return reject("no world") end
	local w = host.world
	if name == "ui" then
		local ui_name, ui_data = data.name, data.data
		if type(ui_name) ~= "string" or #ui_name > 32 then return reject("bad ui action") end
		if type(ui_data) ~= "table" then ui_data = {} end
		if READ_ONLY[ui_name] then
			local msgs = {}
			if ui_name == "select" then
				local id = ui_data.id
				sess.sel = (type(id) == "string" and w:colonist(id)) and id or nil
				msgs[1] = state_msg(sess, true)
			elseif ui_name == "inventory" then
				local o = loc(ui_data.other)
				sess.other = (o and o.kind ~= "player") and o or nil
				msgs[1] = inventory_msg(sess)
			elseif ui_name == "request_summary" then
				msgs[1] = Json.encode({ action = "summary", data = V.summary(w) })
			elseif ui_name == "request_state" then
				msgs[1] = state_msg(sess, true)
			elseif ui_name == "request_catalog" then
				msgs[1] = catalog_json()
			end -- "screens": the in-game owner's colony-view flag; a phone has none
			return envelope(sess, control, msgs)
		end
		if not control then return reject("read-only") end
		if ui_name:sub(1, 6) == "debug_" and not scfg.debug then return reject("debug refused") end
		Phone.stats.ui = Phone.stats.ui + 1
		if ui_name == "new_game" or ui_name == "load" or ui_name == "save" then ctx.log("info", "phone " .. account .. ": " .. ui_name) end
		local ok, why = Net.do_ui(ui_name, ui_data, Phone.token, true)
		if ok == false and why == "rate" then return reject("rate limited") end
		Phone.state_cache = {} -- the world just changed: the answer must show it, not a view up to STATE_MIN_MS old
		local msgs = {}
		if MUTATING_INVENTORY[ui_name] then msgs[1] = inventory_msg(sess) end
		local st = state_msg(sess, true)
		if st then msgs[#msgs + 1] = st end
		return envelope(sess, control, msgs, ok == false and ',"result":false' or "")
	elseif name == "order" or name == "place" then
		local ev = data
		if name == "place" then
			if data.op ~= "commit" then return envelope(sess, control, {}) end -- start / cancel are the in-game placement ghost
			if not tonumber(data.x) or not tonumber(data.y) or type(data.bp) ~= "string" then return reject("bad placement") end
			ev = { id = "colony", kind = "place_blueprint", target = { bp = data.bp, pos = { x = tonumber(data.x), y = tonumber(data.y), z = 0.0 } } } -- as client/ui.lua does
		end
		if not control then return reject("read-only") end
		Phone.stats.orders = Phone.stats.orders + 1
		local ok, why = Net.do_order(ev, Phone.token)
		if ok == false and why == "rate" then return reject("rate limited") end
		Phone.state_cache = {}
		local st = state_msg(sess, true)
		return envelope(sess, control, { st or nil }, ok == false and ',"result":false' or "")
	end
	return reject("unknown callback")
end

-- ---------------------------------------------------------------------------------------------------------------- the exported entry point
-- phoneApi(op, sid, a, b): op = "ready" | "poll" | "cb" | "status". Returns ONE string, the JSON text of the answer (MTA wraps it into a one-element JSON array).
function Phone.api(op, sid, a, b)
	Phone.stats.calls = Phone.stats.calls + 1
	if not Phone.enabled then return reject("the phone companion is switched off (setting phone)") end
	if type(op) ~= "string" then return reject("bad op") end
	if header("x-outbreak-phone") ~= "1" then return reject("missing X-Outbreak-Phone header") end
	local origin, host_h = header("origin"), header("host")
	if origin and origin ~= "null" and (not host_h or origin:match("^https?://([^/]+)$") ~= host_h) then return reject("cross-origin call") end
	local name, control = identity()
	if not name then return reject("forbidden: " .. tostring(control)) end
	if type(sid) ~= "string" or #sid < 8 or #sid > 40 or not sid:match(SID_PATTERN) then return reject("bad session id") end
	if op == "ready" then return op_ready(sid, name, control) end
	if op == "poll" then
		Phone.polls_sec = Phone.polls_sec + 1
		if Phone.polls_sec > MAX_POLLS_PER_SEC then return reject("busy") end
	end
	local sess = get_session(sid, name, control, false)
	if not sess then return '{"ok":true,"resync":true}' end -- expired, evicted, restarted, or another account's id: start over
	if op == "poll" then return op_poll(sess, control, a, b) end
	if op == "cb" then return op_cb(sess, control, name, a, b) end
	if op == "status" then
		local host = ctx.host
		local st = host and host:status() or { world = false }
		return envelope(sess, control, {}, ',"status":' .. Json.encode({ world = st.world, hash = st.hash, day = st.day, time = st.time, colonists = st.colonists, speed = st.speed, paused = st.paused, sessions = Phone.nsessions }))
	end
	return reject("unknown op")
end

-- ---------------------------------------------------------------------------------------------------------------- wiring
function Phone.register()
	Phone.enabled = scfg.phone
	Phone.token = Net.make_bucket(function() return scfg.max_ui_per_sec end)
	Net.on_send = Phone.capture
	ctx.every("phone.sweep", 5000, Phone.sweep)
	ctx.on_cleanup("phone", function() Net.on_send = nil; Phone.sessions, Phone.nsessions, Phone.ring = {}, 0, {}; Phone.state_cache = {} end)
end

-- one line for /outbreak_phone
function Phone.describe()
	local s = Phone.stats
	local control, view = 0, 0
	for _, v in pairs(Phone.sessions) do if v.control then control = control + 1 else view = view + 1 end end
	local reasons = {}
	for k, n in pairs(s.reasons) do reasons[#reasons + 1] = k .. " x" .. n end
	table.sort(reasons)
	return string.format("phone %s | sessions %d (control %d, view %d) | calls %d polls %d callbacks %d readies %d | orders %d ui %d | refused %d%s | ring %d msgs / %d bytes, generation %d | expired %d evicted %d",
		Phone.enabled and "on" or "OFF", Phone.nsessions, control, view, s.calls, s.polls, s.callbacks, s.readies, s.orders, s.ui, s.rejected, #reasons > 0 and (" (" .. table.concat(reasons, ", ") .. ")") or "",
		Phone.seq - Phone.first + 1, Phone.bytes, Phone.generation, s.expired, s.evicted)
end

return Phone
