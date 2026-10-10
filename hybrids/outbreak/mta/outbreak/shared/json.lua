-- shared/json.lua : minimal JSON encoder (no decoder needed: the browser decodes) for hosts without a native `json`
-- (the wasmoon browser preview and the test harness). FiveM has its own `json.encode`; the server/client never use this file.
-- Output is deterministic (object keys sorted). Empty tables encode as [] (the UI treats [] and {} alike).
-- Numbers: integers print without a decimal point; non-finite numbers become null.
local M = {}

local format, concat = string.format, table.concat
local floor = math.floor

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function esc_char(c) return ESC[c] or format("\\u%04x", c:byte()) end

local function quote(s)
	return '"' .. s:gsub('[%c"\\]', esc_char) .. '"'
end

local function num(n)
	if n ~= n or n == math.huge or n == -math.huge then return "null" end
	if n == floor(n) and n > -1e15 and n < 1e15 then return format("%d", n) end
	return format("%.10g", n)
end

local function sorted_keys(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end -- sorted below
	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then return ta < tb end
		return a < b
	end)
	return keys
end

local function enc(v, buf, n, depth)
	local t = type(v)
	if t == "nil" then n = n + 1; buf[n] = "null"
	elseif t == "boolean" then n = n + 1; buf[n] = v and "true" or "false"
	elseif t == "number" then n = n + 1; buf[n] = num(v)
	elseif t == "string" then n = n + 1; buf[n] = quote(v)
	elseif t == "table" then
		if depth > 40 then error("json: too deep (cycle?)", 0) end
		local count = 0
		for _ in pairs(v) do count = count + 1 end -- counting only
		if count == 0 then
			n = n + 1; buf[n] = "[]"
		elseif count == #v then
			n = n + 1; buf[n] = "["
			for i = 1, count do
				if i > 1 then n = n + 1; buf[n] = "," end
				n = enc(v[i], buf, n, depth + 1)
			end
			n = n + 1; buf[n] = "]"
		else
			local keys = sorted_keys(v)
			n = n + 1; buf[n] = "{"
			local first = true
			for i = 1, #keys do
				local k = keys[i]
				if not first then n = n + 1; buf[n] = "," end
				first = false
				n = n + 1; buf[n] = quote(tostring(k))
				n = n + 1; buf[n] = ":"
				n = enc(v[k], buf, n, depth + 1)
			end
			n = n + 1; buf[n] = "}"
		end
	else
		n = n + 1; buf[n] = "null"
	end
	return n
end

function M.encode(v)
	local buf = {}
	enc(v, buf, 0, 0)
	return concat(buf)
end

-- ---------------------------------------------------------------------------------------------------------------------
-- decoder (used by the browser preview to read orders / UI actions sent as JSON text). Standard JSON; `null` becomes nil.
-- ---------------------------------------------------------------------------------------------------------------------
local function utf8_char(cp)
	if cp < 0x80 then return string.char(cp) end
	if cp < 0x800 then return string.char(0xC0 + floor(cp / 64), 0x80 + cp % 64) end
	if cp < 0x10000 then return string.char(0xE0 + floor(cp / 4096), 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64) end
	return string.char(0xF0 + floor(cp / 262144), 0x80 + floor(cp / 4096) % 64, 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
end

local function derr(s, i, msg) error(format("json: %s at %d", msg, i), 0) end

local function skip(s, i)
	return s:find("[^ \t\r\n]", i) or #s + 1
end

local dval
local UNESC = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function dstr(s, i)
	local out, n = {}, 0
	i = i + 1
	while true do
		local j = s:find('["\\]', i)
		if not j then derr(s, i, "unterminated string") end
		if j > i then n = n + 1; out[n] = s:sub(i, j - 1) end
		if s:sub(j, j) == '"' then return concat(out), j + 1 end
		local c = s:sub(j + 1, j + 1)
		if c == "u" then
			local hex = s:match("^%x%x%x%x", j + 2)
			if not hex then derr(s, j, "bad \\u escape") end
			local cp = tonumber(hex, 16)
			local nexti = j + 6
			if cp >= 0xD800 and cp < 0xDC00 then
				local lo = s:match("^\\u(%x%x%x%x)", nexti)
				if lo then cp = 0x10000 + (cp - 0xD800) * 1024 + (tonumber(lo, 16) - 0xDC00); nexti = nexti + 6 end
			end
			n = n + 1; out[n] = utf8_char(cp)
			i = nexti
		else
			local u = UNESC[c]
			if not u then derr(s, j, "bad escape") end
			n = n + 1; out[n] = u
			i = j + 2
		end
	end
end

dval = function(s, i, depth)
	if depth > 60 then derr(s, i, "too deep") end
	i = skip(s, i)
	local c = s:sub(i, i)
	if c == "{" then
		local t = {}
		i = skip(s, i + 1)
		if s:sub(i, i) == "}" then return t, i + 1 end
		while true do
			if s:sub(i, i) ~= '"' then derr(s, i, "expected key") end
			local k
			k, i = dstr(s, i)
			i = skip(s, i)
			if s:sub(i, i) ~= ":" then derr(s, i, "expected ':'") end
			local v
			v, i = dval(s, i + 1, depth + 1)
			t[k] = v
			i = skip(s, i)
			local d = s:sub(i, i)
			if d == "," then i = skip(s, i + 1) elseif d == "}" then return t, i + 1 else derr(s, i, "expected ',' or '}'") end
		end
	elseif c == "[" then
		local t, n = {}, 0
		i = skip(s, i + 1)
		if s:sub(i, i) == "]" then return t, i + 1 end
		while true do
			local v
			v, i = dval(s, i, depth + 1)
			n = n + 1; t[n] = v
			i = skip(s, i)
			local d = s:sub(i, i)
			if d == "," then i = i + 1 elseif d == "]" then return t, i + 1 else derr(s, i, "expected ',' or ']'") end
		end
	elseif c == '"' then
		return dstr(s, i)
	elseif s:sub(i, i + 3) == "true" then return true, i + 4
	elseif s:sub(i, i + 4) == "false" then return false, i + 5
	elseif s:sub(i, i + 3) == "null" then return nil, i + 4
	else
		local num = s:match("^-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
		if not num or num == "" then derr(s, i, "unexpected character") end
		local v = tonumber(num)
		if v == nil then derr(s, i, "bad number") end
		return v, i + #num
	end
end

-- returns the Lua value, or nil + error text for malformed input
function M.decode(s)
	if type(s) ~= "string" then return nil, "not a string" end
	local ok, v, i = pcall(dval, s, 1, 0)
	if not ok then return nil, v end
	i = skip(s, i)
	if i <= #s then return nil, "json: trailing data" end
	return v
end

return M
