-- mta/tools/function_check.lua : verifies that EVERY global the resource's Lua reads is something MTA:SA really provides on the side (client / server) that runs it,
-- that nothing writes an accidental global, that no library function missing from MTA's Lua 5.1 is used, and that every triggerClientEvent / triggerServerEvent name
-- is registered with addEvent (remote = true) on the receiving side.
--
--   lua5.4 mta/tools/function_check.lua [--resource DIR] [--src MTASA_BLUE_DIR] [--luac luac5.4] [--list] [--markdown] [--quiet] [--allow-global NAME]
--
-- Sources of truth (clone of multitheftauto/mtasa-blue, GPL-3.0: READ ONLY, only names are looked up, see tools/mta_defs.lua):
--   the C++ registration tables of the Client / Server / Shared Lua definitions  -> which function exists on which side
--   CClientGame.cpp / CGame.cpp                                                   -> built-in event names per side
-- How globals are found: the file is compiled with `luac -l -l` (Lua 5.4's compiler listing) and every GETTABUP / SETTABUP on _ENV is a read / write of a global, with its
-- real line number. That is exact (locals, parameters and upvalues are never mistaken for globals, unlike a text scan).
-- Which side a file runs on: server/ -> server, client/ -> client, everything else (shared/, sim/, data/, bootstrap_mta.lua) -> both, so it must be valid on both.
-- Exit code 0 = clean, 1 = problems found, 2 = the tool could not run (missing source clone, luac, resource).
local here = (arg and arg[0] or "function_check.lua"):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local Defs = require("mta_defs")

local opt = { resource = here .. "/../outbreak", src = nil, luac = os.getenv("LUAC") or "luac5.4", list = false, markdown = false, quiet = false, allow = { OB_BOOT = true, OutbreakHost = true, OutbreakClient = true, phoneApi = true } }
do
	local a, i = { ... }, 1
	while i <= #a do
		local x = a[i]
		if x == "--resource" then opt.resource = a[i + 1]; i = i + 1
		elseif x == "--src" then opt.src = a[i + 1]; i = i + 1
		elseif x == "--luac" then opt.luac = a[i + 1]; i = i + 1
		elseif x == "--list" then opt.list = true
		elseif x == "--markdown" then opt.markdown = true
		elseif x == "--quiet" then opt.quiet = true
		elseif x == "--allow-global" then opt.allow[a[i + 1]] = true; i = i + 1 end
		i = i + 1
	end
end

local function die(msg) io.stderr:write("function_check: " .. msg .. "\n"); os.exit(2) end
local function read(path) local f = io.open(path, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end

local defs, derr = Defs.load(opt.src)
if not defs then die(derr) end

local function set_of(list) local s = {} for _, v in ipairs(list) do s[v] = true end return s end
local lua_ok, lua_disabled, lua_bad = set_of(Defs.lua_globals), set_of(Defs.disabled_globals), set_of(Defs.bad_globals)
local mta_vars = { server = set_of(Defs.mta_globals_both), client = set_of(Defs.mta_globals_both) }
for _, n in ipairs(Defs.mta_globals_server) do mta_vars.server[n] = true end
for _, n in ipairs(Defs.mta_globals_client) do mta_vars.client[n] = true end

-- ---------------------------------------------------------------------------------------------------------------- files
local files = {}
do
	local p = io.popen('find "' .. opt.resource .. '" -name "*.lua" 2>/dev/null | sort')
	if p then for f in p:lines() do files[#files + 1] = f end p:close() end
	if #files == 0 then die("no Lua files under " .. opt.resource) end
end
local root = opt.resource:gsub("/+$", "")
local function rel(f) return (f:gsub("^" .. root:gsub("%p", "%%%0") .. "/", "")) end
local function side_of(f)
	local r = rel(f)
	if r:match("^server/") then return "server" end
	if r:match("^client/") then return "client" end
	return "shared"
end
local function sides(side) if side == "shared" then return { "server", "client" } end return { side } end

-- ---------------------------------------------------------------------------------------------------------------- text helpers
-- blank out comments (keep_strings = true keeps string literals; false blanks their contents too). Length and line structure are preserved, so a position in one result is the same
-- position in the other.
local function strip(src, keep_strings)
	local out, i, n = {}, 1, #src
	while i <= n do
		local c = src:sub(i, i)
		if c == "-" and src:sub(i, i + 1) == "--" then
			local lvl = src:match("^%-%-%[(=*)%[", i)
			if lvl then
				local close = "]" .. lvl .. "]"
				local j = src:find(close, i, true) or n
				out[#out + 1] = (src:sub(i, j + #close - 1):gsub("[^\n]", " "))
				i = j + #close
			else
				local j = src:find("\n", i, true) or (n + 1)
				out[#out + 1] = string.rep(" ", j - i)
				i = j
			end
		elseif c == "[" and src:match("^%[=*%[", i) then
			local lvl = src:match("^%[(=*)%[", i)
			local close = "]" .. lvl .. "]"
			local j = src:find(close, i, true) or n
			local chunk = src:sub(i, j + #close - 1)
			out[#out + 1] = keep_strings and chunk or (chunk:gsub("[^\n]", " ")) -- same length, same lines
			i = j + #close
		elseif c == '"' or c == "'" then
			local j = i + 1
			while j <= n do
				local d = src:sub(j, j)
				if d == "\\" then j = j + 2 elseif d == c or d == "\n" then break else j = j + 1 end
			end
			if keep_strings then out[#out + 1] = src:sub(i, j) else out[#out + 1] = c .. string.rep(" ", math.max(0, j - i - 1)) .. c end -- same length: positions line up
			i = j + 1
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

local function line_of(text, pos) local _, n = text:sub(1, pos):gsub("\n", ""); return n + 1 end

-- split the argument list that starts at text[open] == "(" ; returns { arg strings }, index after the closing paren
local function split_args(text, open)
	local args, depth, cur, i, n = {}, 0, {}, open, #text
	while i <= n do
		local c = text:sub(i, i)
		if c == '"' or c == "'" then
			local j = i + 1
			while j <= n do
				local d = text:sub(j, j)
				if d == "\\" then j = j + 2 elseif d == c then break else j = j + 1 end
			end
			cur[#cur + 1] = text:sub(i, j); i = j
		elseif c == "(" or c == "{" or c == "[" then
			depth = depth + 1
			if depth > 1 then cur[#cur + 1] = c end
		elseif c == ")" or c == "}" or c == "]" then
			depth = depth - 1
			if depth == 0 then
				local last = table.concat(cur):gsub("^%s+", ""):gsub("%s+$", "")
				if last ~= "" or #args > 0 then args[#args + 1] = last end
				return args, i + 1
			end
			cur[#cur + 1] = c
		elseif c == "," and depth == 1 then
			args[#args + 1] = (table.concat(cur):gsub("^%s+", ""):gsub("%s+$", "")); cur = {}
		else
			cur[#cur + 1] = c
		end
		i = i + 1
	end
	return args, n + 1
end

-- ---------------------------------------------------------------------------------------------------------------- 1. globals via luac -l -l
local reads, writes = {}, {}   -- per file: list of { name, line }
local function listing(file)
	local p = io.popen(string.format('%s -l -l -o /dev/null "%s" 2>&1', opt.luac, file))
	if not p then die("cannot run " .. opt.luac) end
	local out = p:read("*a")
	local ok = p:close()
	return out, ok
end
for _, f in ipairs(files) do
	local out = listing(f)
	if out:find("luac[%w%.]*: ", 1) and not out:find("\nmain ", 1, true) and not out:match("^main ") then
		die("cannot compile " .. f .. " with " .. opt.luac .. ": " .. out:sub(1, 200))
	end
	local r, w = {}, {}
	for line, op, name in out:gmatch('%[(%d+)%]%s+(%u+)[^\n]-;%s+_ENV%s+"([^"]+)"') do
		if op == "GETTABUP" then r[#r + 1] = { name = name, line = tonumber(line) }
		elseif op == "SETTABUP" then w[#w + 1] = { name = name, line = tonumber(line) } end
	end
	reads[f], writes[f] = r, w
end

-- globals the resource defines itself, per side (a shared file defines them on both)
local defined = { server = {}, client = {} }
local problems = {}
local function problem(fmt, ...) problems[#problems + 1] = string.format(fmt, ...) end
-- MTA's `require` is a disabled stub; the resource installs its own over fileOpen (bootstrap_mta.lua, `_G.require = ...`). That counts as a definition, but only if the file really does it.
do
	local boot = read(root .. "/bootstrap_mta.lua")
	if boot and boot:find("_G.require%s*=") then defined.server.require, defined.client.require = true, true end
end
for _, f in ipairs(files) do
	for _, w in ipairs(writes[f]) do
		for _, sd in ipairs(sides(side_of(f))) do defined[sd][w.name] = true end
		if not opt.allow[w.name] then problem("GLOBAL WRITE %s at %s:%d (a leaked global or a typo; use `local`, or --allow-global %s if it is deliberate)", w.name, rel(f), w.line, w.name) end
	end
end

local uses = {}      -- name -> { count, where = {..}, sides = { server = bool, client = bool }, kind = "mta" | "lua" | "own" }
for _, f in ipairs(files) do
	local fside = side_of(f)
	for _, rd in ipairs(reads[f]) do
		local name = rd.name
		for _, sd in ipairs(sides(fside)) do
			local kind
			if lua_ok[name] then kind = "lua"
			elseif defined[sd][name] and lua_disabled[name] then kind = "own"
			elseif lua_disabled[name] then problem("DISABLED in MTA: %s at %s:%d (CLuaMain::InitSecurity replaces it with a stub)", name, rel(f), rd.line)
			elseif lua_bad[name] then problem("NOT IN MTA's Lua 5.1: %s at %s:%d", name, rel(f), rd.line)
			elseif mta_vars[sd][name] then kind = "lua"
			elseif defined[sd][name] then kind = "own"
			elseif defs[sd][name] then kind = "mta"
			else
				local other = (sd == "server") and "client" or "server"
				if defs[other][name] then problem("%s is not available on the %s but is used there (%s:%d); it exists on the %s only", name, sd:upper(), rel(f), rd.line, other:upper())
				else problem("UNKNOWN function or global %s at %s:%d (%s side)", name, rel(f), rd.line, sd:upper()) end
			end
			if kind == "mta" or kind == "lua" then
				local u = uses[name]
				if not u then u = { count = 0, where = {}, sides = {}, kind = kind }; uses[name] = u end
				u.count = u.count + 1
				u.sides[sd] = true
				if #u.where < 3 then u.where[#u.where + 1] = rel(f) .. ":" .. rd.line end
			end
		end
	end
end

-- ---------------------------------------------------------------------------------------------------------------- 2. library fields that MTA's Lua 5.1 lacks
local texts, codes = {}, {}      -- file -> comment-stripped source (strings kept) / code only (comments and string contents blanked, same length)
for _, f in ipairs(files) do
	local src = read(f) or die("cannot read " .. f)
	texts[f] = strip(src, true)
	local nostr = strip(src, false)
	codes[f] = nostr
	local nostr_lines = {}
	for l in (nostr .. "\n"):gmatch("([^\n]*)\n") do nostr_lines[#nostr_lines + 1] = l end
	for lib, bad in pairs(Defs.bad_fields) do
		local badset = set_of(bad)
		for pos, field in nostr:gmatch("%f[%w_.:]" .. lib .. "()%.([%a_][%w_]*)") do
			if badset[field] then
				local ln = line_of(nostr, pos)
				local text_line = nostr_lines[ln] or ""
				-- the portable idiom `table.unpack or unpack` (5.4 / 5.1) is fine: the 5.4 branch is simply nil in MTA
				if not (lib == "table" and field == "unpack" and text_line:find("or%s+unpack")) then problem("NOT IN MTA's Lua 5.1: %s.%s at %s:%d", lib, field, rel(f), ln) end
			end
		end
	end
end

-- ---------------------------------------------------------------------------------------------------------------- 3. event names
-- NET.xxx / P.NET.xxx names are resolved against shared/mta_net.lua (loaded with the resource folder on the search path)
local NET = {}
do
	local saved = package.path
	package.path = root .. "/?.lua;" .. package.path
	for k in pairs(package.loaded) do if k:match("^shared%.") then package.loaded[k] = nil end end
	local ok, mod = pcall(require, "shared.mta_net")
	package.path = saved
	if ok and type(mod) == "table" then NET = mod end
end
-- `NET.wire(topic)` maps a host topic to a wire name at run time; it can only produce the names in NET.TO_CLIENT, so every one of them is checked
local function resolve(expr, f, line)
	if expr:match("^NET%.wire%s*%(") and type(NET.TO_CLIENT) == "table" then return NET.TO_CLIENT end
	local lit = expr:match('^"([^"]*)"$') or expr:match("^'([^']*)'$")
	if lit then return lit end
	local field = expr:match("^[%a_][%w_]*%.([%a_][%w_]*)$") or expr:match("^[%a_][%w_]*%.NET%.([%a_][%w_]*)$")
	local base = expr:match("^([%a_][%w_]*)%.")
	if field and (base == "NET" or base == "N" or expr:find("NET%.")) and type(NET[field]) == "string" then return NET[field] end
	problem("CANNOT RESOLVE the event name expression `%s` at %s:%d (use a string literal or NET.<field> from shared/mta_net.lua)", expr, rel(f), line)
	return nil
end

local registered = { server = {}, client = {} }    -- name -> remote bool
local handlers = { server = {}, client = {} }
local calls = {}
for _, f in ipairs(files) do
	local text, code = texts[f], codes[f]
	local function each(fname, fn)
		local init = 1
		while true do
			local s, e = code:find("%f[%w_.:]" .. fname .. "%s*%(", init) -- a call in the CODE (not inside a string); its arguments are read from the text that keeps strings
			if not s then break end
			local args, after = split_args(text, e)
			fn(args, line_of(text, s))
			init = after
		end
	end
	local fs = side_of(f)
	each("addEvent", function(args, line)
		local name = resolve(args[1] or "", f, line)
		local remote = args[2] == "true"
		if name then for _, sd in ipairs(sides(fs)) do registered[sd][name] = remote or registered[sd][name] or false end end
	end)
	each("addEventHandler", function(args, line)
		local name = resolve(args[1] or "", f, line)
		if name then for _, sd in ipairs(sides(fs)) do handlers[sd][#handlers[sd] + 1] = { name = name, where = rel(f) .. ":" .. line } end end
	end)
	each("triggerClientEvent", function(args, line)
		local first = args[1] or ""
		local idx = (first:match('^["\']') or first:match("NET%.") or first:match("^NET%.")) and 1 or 2
		local name = resolve(args[idx] or "", f, line)
		if type(name) == "table" then
			for _, n in ipairs(name) do calls[#calls + 1] = { kind = "client", name = n, where = rel(f) .. ":" .. line } end
		elseif name then calls[#calls + 1] = { kind = "client", name = name, where = rel(f) .. ":" .. line } end
	end)
	each("triggerServerEvent", function(args, line)
		local name = resolve(args[1] or "", f, line)
		if name then calls[#calls + 1] = { kind = "server", name = name, where = rel(f) .. ":" .. line } end
	end)
end
local n_events = 0
local seen_calls = {}
for _, c in ipairs(calls) do
	local target = (c.kind == "client") and "client" or "server"   -- triggerClientEvent lands on the client, triggerServerEvent on the server
	local key = c.kind .. ":" .. c.name
	if not seen_calls[key] then
		seen_calls[key] = true
		n_events = n_events + 1
		local r = registered[target][c.name]
		if r == nil then problem("EVENT %s is sent with %s (%s) but never registered with addEvent on the %s", c.name, c.kind == "client" and "triggerClientEvent" or "triggerServerEvent", c.where, target:upper())
		elseif r == false then problem("EVENT %s is registered on the %s with addEvent(name, false): a remote trigger (%s) is rejected; it needs allowRemoteTrigger = true", c.name, target:upper(), c.where) end
	end
end
for _, sd in ipairs({ "server", "client" }) do
	for _, h in ipairs(handlers[sd]) do
		if registered[sd][h.name] == nil and not defs.events[sd][h.name] then problem("EVENT HANDLER for %s (%s) on the %s: neither a built-in %s event nor registered with addEvent", h.name, h.where, sd:upper(), sd) end
	end
end

-- ---------------------------------------------------------------------------------------------------------------- report
local names = {}
for nm in pairs(uses) do names[#names + 1] = nm end
table.sort(names)
local mta_names = {}
for _, nm in ipairs(names) do if uses[nm].kind == "mta" then mta_names[#mta_names + 1] = nm end end

if opt.markdown then
	print("| function | side | first use |")
	print("|---|---|---|")
	for _, nm in ipairs(mta_names) do
		local u = uses[nm]
		local both = u.sides.server and u.sides.client
		print(string.format("| `%s` | %s | %s |", nm, both and "both" or (u.sides.server and "server" or "client"), u.where[1]))
	end
elseif not opt.quiet then
	print(string.format("function_check: %d Lua files scanned under %s", #files, opt.resource))
	print(string.format("function_check: definitions: %d client + %d server functions (%d in the shared defs), %d client + %d server built-in events, from %s",
		defs.counts.client, defs.counts.server, defs.counts.shared, defs.counts.client_events, defs.counts.server_events, defs.src))
	print(string.format("function_check: %d distinct MTA functions used, %d remote event names checked", #mta_names, n_events))
	if opt.list then
		for _, nm in ipairs(mta_names) do
			local u = uses[nm]
			local ss = {}
			for s in pairs(u.sides) do ss[#ss + 1] = s end
			table.sort(ss)
			print(string.format("  %-34s x%-4d [%s] %s", nm, u.count, table.concat(ss, "+"), u.where[1]))
		end
	end
end

local seen, uniq = {}, {}
for _, p in ipairs(problems) do if not seen[p] then seen[p] = true; uniq[#uniq + 1] = p end end
if #uniq > 0 then
	for _, p in ipairs(uniq) do print("FAIL " .. p) end
	print(string.format("function_check: FAILED with %d problem(s)", #uniq))
	os.exit(1)
end
if not opt.quiet and not opt.markdown then print("function_check: OK, every function exists on the side that uses it, no leaked globals, every remote event is registered") end
os.exit(0)
