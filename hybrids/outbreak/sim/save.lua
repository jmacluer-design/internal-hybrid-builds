-- save.lua : deterministic canonical serializer (sorted keys, one number format), versioned header,
-- migrations table, and load(save(w)) round-tripping to an identical state hash.
--
--   header line :  OUTBREAK-SAVE <version> <payload length> <payload hash>\n
--   payload     :  canonical text of w.s:  null-free JSON-like  { "k":v, ... }  [ v, ... ]  "str"  number  true|false
-- Rules the state must obey (the serializer errors loudly otherwise): maps have string keys, arrays are dense
-- 1..n, numbers are finite, no functions / userdata / cycles. Metatables are ignored (rng tables are re-attached
-- by World.restore).
local U = require("sim.util")

local M = {}
M.CURRENT_VERSION = 2

-- ---------------------------------------------------------------------------------------------
-- canonical serializer
-- ---------------------------------------------------------------------------------------------
local fmt_num = U.fmt_num
local byte, format = string.byte, string.format

local function esc_char(c) return format("\\x%02x", byte(c)) end

local function quote(s)
	-- escape backslash, quote and control bytes
	s = s:gsub('[%c"\\]', esc_char)
	return '"' .. s .. '"'
end

local function ser(v, buf, n, depth)
	local t = type(v)
	if t == "number" then
		n = n + 1; buf[n] = fmt_num(v)
	elseif t == "string" then
		n = n + 1; buf[n] = quote(v)
	elseif t == "boolean" then
		n = n + 1; buf[n] = v and "true" or "false"
	elseif t == "table" then
		if depth > 60 then error("save: structure too deep (cycle?)") end
		local len = #v
		local count = 0
		for _ in pairs(v) do count = count + 1 end -- order-free
		if count == 0 then
			n = n + 1; buf[n] = "[]"
		elseif count == len then
			n = n + 1; buf[n] = "["
			for i = 1, len do
				if i > 1 then n = n + 1; buf[n] = "," end
				n = ser(v[i], buf, n, depth + 1)
			end
			n = n + 1; buf[n] = "]"
		else
			local keys = {}
			for k in pairs(v) do -- order-free: sorted below
				if type(k) ~= "string" then error("save: non-string key in a map: " .. tostring(k)) end
				keys[#keys + 1] = k
			end
			table.sort(keys)
			n = n + 1; buf[n] = "{"
			for i = 1, #keys do
				if i > 1 then n = n + 1; buf[n] = "," end
				n = n + 1; buf[n] = quote(keys[i])
				n = n + 1; buf[n] = ":"
				n = ser(v[keys[i]], buf, n, depth + 1)
			end
			n = n + 1; buf[n] = "}"
		end
	else
		error("save: cannot serialize a " .. t)
	end
	return n
end

function M.serialize(v)
	local buf = {}
	ser(v, buf, 0, 0)
	return table.concat(buf)
end

-- ---------------------------------------------------------------------------------------------
-- parser
-- ---------------------------------------------------------------------------------------------
local function perr(s, i, msg)
	error(format("save: parse error at %d: %s (near %q)", i, msg, s:sub(i, i + 12)), 0)
end

local parse_value

local function parse_string(s, i)
	-- s:sub(i,i) == '"'
	local out, n = {}, 0
	i = i + 1
	while true do
		local j = s:find('["\\]', i)
		if not j then perr(s, i, "unterminated string") end
		if j > i then n = n + 1; out[n] = s:sub(i, j - 1) end
		if s:sub(j, j) == '"' then
			return table.concat(out), j + 1
		end
		-- escape: \xHH
		local hex = s:match("^x(%x%x)", j + 1)
		if not hex then perr(s, j, "bad escape") end
		n = n + 1; out[n] = string.char(tonumber(hex, 16))
		i = j + 4
	end
end

parse_value = function(s, i)
	local c = s:sub(i, i)
	if c == "{" then
		local t = {}
		i = i + 1
		if s:sub(i, i) == "}" then return t, i + 1 end
		while true do
			if s:sub(i, i) ~= '"' then perr(s, i, "expected key") end
			local k
			k, i = parse_string(s, i)
			if s:sub(i, i) ~= ":" then perr(s, i, "expected ':'") end
			local v
			v, i = parse_value(s, i + 1)
			t[k] = v
			local d = s:sub(i, i)
			if d == "," then i = i + 1 elseif d == "}" then return t, i + 1 else perr(s, i, "expected ',' or '}'") end
		end
	elseif c == "[" then
		local t, n = {}, 0
		i = i + 1
		if s:sub(i, i) == "]" then return t, i + 1 end
		while true do
			local v
			v, i = parse_value(s, i)
			n = n + 1; t[n] = v
			local d = s:sub(i, i)
			if d == "," then i = i + 1 elseif d == "]" then return t, i + 1 else perr(s, i, "expected ',' or ']'") end
		end
	elseif c == '"' then
		return parse_string(s, i)
	elseif s:sub(i, i + 3) == "true" then
		return true, i + 4
	elseif s:sub(i, i + 4) == "false" then
		return false, i + 5
	else
		local num = s:match("^-?[%d%.]+[eE]?[%+%-]?%d*", i)
		if not num or num == "" then perr(s, i, "unexpected character") end
		local v = tonumber(num)
		if v == nil then perr(s, i, "bad number") end
		return v, i + #num
	end
end

function M.deserialize(s)
	local v, i = parse_value(s, 1)
	if i <= #s then perr(s, i, "trailing data") end
	return v
end

-- ---------------------------------------------------------------------------------------------
-- hashing, saving, loading, migrations
-- ---------------------------------------------------------------------------------------------
function M.hash_state(state) return U.hash(M.serialize(state)) end

-- migrations[n] upgrades a version-n state table to version n+1 (in place) and returns it
M.migrations = {}

-- v1 -> v2: v1 had no daily history and no cached day number
M.migrations[1] = function(state)
	local clock = require("sim.clock")
	state.history = state.history or {}
	state.day = state.day or clock.day(state.t)
	state.version = 2
	return state
end

function M.migrate(state, from_version)
	local v = from_version
	while v < M.CURRENT_VERSION do
		local f = M.migrations[v]
		if not f then error(string.format("save: no migration from version %d", v), 0) end
		state = f(state)
		v = v + 1
	end
	return state
end

function M.save(w)
	local payload = M.serialize(w.s)
	return format("OUTBREAK-SAVE %d %d %s\n", w.s.version or M.CURRENT_VERSION, #payload, U.hash(payload)) .. payload
end

-- pack an arbitrary state table with a given version header (used by the migration tests)
function M.pack(state, version)
	local payload = M.serialize(state)
	return format("OUTBREAK-SAVE %d %d %s\n", version, #payload, U.hash(payload)) .. payload
end

-- returns the plain state table (migrated to the current version) or nil, error
function M.unpack(str)
	local ver, len, hash, rest = str:match("^OUTBREAK%-SAVE (%d+) (%d+) (%x+)\n()")
	if not ver then return nil, "not a save file" end
	ver, len = tonumber(ver), tonumber(len)
	local payload = str:sub(rest)
	if #payload ~= len then return nil, "truncated save (length mismatch)" end
	if U.hash(payload) ~= hash then return nil, "corrupt save (hash mismatch)" end
	if ver > M.CURRENT_VERSION then return nil, string.format("save is from a newer version (%d)", ver) end
	local ok, state = pcall(M.deserialize, payload)
	if not ok then return nil, state end
	if type(state) ~= "table" then return nil, "bad payload" end
	local mok, merr = pcall(M.migrate, state, ver)
	if not mok then return nil, merr end
	return merr
end

function M.load(str)
	local state, err = M.unpack(str)
	if not state then return nil, err end
	return require("sim.world").restore(state)
end

return M
