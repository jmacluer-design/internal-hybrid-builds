-- mta/tools/mta_defs.lua : reads the REAL list of MTA:SA Lua functions (per side) and built-in events out of a clone of multitheftauto/mtasa-blue.
-- READ ONLY: mtasa-blue is GPL-3.0, so nothing is copied from it, only function and event NAMES are looked up (the same way fivem/tools/native_check.lua reads FiveM's
-- native lists). Used by tools/function_check.lua and by the test harness (tests/mock_mta.lua gives each side only the functions that exist there).
--
-- Where MTA registers its Lua functions (checked against the source):
--   Client:  Client/mods/deathmatch/logic/luadefs/*.cpp  + Client/mods/deathmatch/logic/lua/*.cpp (CLuaManager.cpp registers the core: addEventHandler, bindKey, ...)
--   Server:  Server/mods/deathmatch/logic/luadefs/*.cpp  + Server/mods/deathmatch/logic/lua/*.cpp      (CLuaHTTPDefs.cpp is HTMLD-only and skipped)
--   Shared:  Shared/mods/deathmatch/logic/luadefs/*.cpp  (file*, xml*, bit*, vector*, getTickCount, getRealTime, ... on both sides: CLuaShared::LoadFunctions)
--   entries look like   {"createPed", CreatePed},   {"setPedAnimation", ArgumentParserWarn<false, SetPedAnimation>},   or   AddFunction("name", ...)
--   built-in events:    m_Events.AddEvent("onClientRender", "", NULL, false);   in Client/.../CClientGame.cpp and Server/.../CGame.cpp
-- Lua's own library (MTA opens base, math, string, table, debug, utf8, os and disables dofile, loadfile, require, loadlib, getfenv, newproxy and os.execute / rename /
-- remove / exit / getenv / tmpname / setlocale: CLuaMain::InitSecurity) is listed below by hand, with that source reference.
local D = {}

local function read(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local function list_files(dir, pattern)
	local out = {}
	local p = io.popen('find "' .. dir .. '" -maxdepth 1 -type f -name "' .. pattern .. '" 2>/dev/null | sort')
	if p then for f in p:lines() do out[#out + 1] = f end p:close() end
	return out
end

-- function names registered in one C++ file
local function scan_functions(text, into)
	local n = 0
	for name, rest in text:gmatch('{%s*"([%a_][%w_]*)"%s*,%s*([^"\n]-)}') do
		if rest:match("^[%a_][%w_:<>%s,&]*$") then
			if not into[name] then into[name] = true; n = n + 1 end
		end
	end
	for name in text:gmatch('AddFunction%s*%(%s*"([%a_][%w_]*)"') do
		if not into[name] then into[name] = true; n = n + 1 end
	end
	return n
end

local function scan_events(text, into)
	for name in text:gmatch('AddEvent%s*%(%s*"([%a_][%w_]*)"') do into[name] = true end
end

-- load(src) -> defs, or nil + error message.   defs = { client = set, server = set, events = { client = set, server = set }, counts = {...}, src = dir }
function D.load(src)
	src = src or os.getenv("MTASA_SRC") or "/home/user/multitheftauto/mtasa-blue"
	local base = src .. "/"
	local defs = { client = {}, server = {}, shared = {}, events = { client = {}, server = {} }, src = src, counts = {} }
	local function add(dir, into, skip)
		local files = list_files(base .. dir, "*.cpp")
		local nfiles = 0
		for _, f in ipairs(files) do
			if not (skip and f:find(skip, 1, true)) then
				local text = read(f)
				if text then scan_functions(text, into); nfiles = nfiles + 1 end
			end
		end
		return nfiles
	end
	local nc = add("Client/mods/deathmatch/logic/luadefs", defs.client) + add("Client/mods/deathmatch/logic/lua", defs.client)
	local ns = add("Server/mods/deathmatch/logic/luadefs", defs.server, "CLuaHTTPDefs") + add("Server/mods/deathmatch/logic/lua", defs.server)
	local nh = add("Shared/mods/deathmatch/logic/luadefs", defs.shared)
	if nc == 0 or ns == 0 or nh == 0 then
		return nil, "no MTA function definitions found under " .. src .. " (clone multitheftauto/mtasa-blue there: see mta/README.md, 'Function check')"
	end
	for name in pairs(defs.shared) do defs.client[name] = true; defs.server[name] = true end
	local cg, sg = read(base .. "Client/mods/deathmatch/logic/CClientGame.cpp"), read(base .. "Server/mods/deathmatch/logic/CGame.cpp")
	if not cg or not sg then return nil, "CClientGame.cpp / CGame.cpp (built-in event lists) are missing under " .. src end
	scan_events(cg, defs.events.client)
	scan_events(sg, defs.events.server)
	local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
	defs.counts = { client = count(defs.client), server = count(defs.server), shared = count(defs.shared), client_events = count(defs.events.client), server_events = count(defs.events.server) }
	return defs
end

-- ---------------------------------------------------------------------------------------------------------------- Lua itself (MTA = Lua 5.1)
-- globals available in an MTA script: luaopen_base (Lua 5.1 base functions + coroutine), math, string, table, debug, utf8, os; plus the globals MTA defines
-- (CLuaMain::Initialize: root, resource, resourceRoot, resourceName, client: guiRoot, localPlayer; event context: source, this, client, eventName, sourceResource,
-- sourceResourceRoot, sourceTimer; embedded scripts: exports, inspect)
D.lua_globals = {
	"assert", "collectgarbage", "error", "getmetatable", "ipairs", "load", "loadstring", "next", "pairs", "pcall", "print", "rawequal", "rawget", "rawset", "select",
	"setfenv", "setmetatable", "tonumber", "tostring", "type", "unpack", "xpcall", "_G", "_VERSION", "coroutine", "debug", "math", "os", "string", "table", "utf8",
}
-- stock Lua 5.1 functions that MTA replaces with a disabled stub (CLuaMain::InitSecurity)
D.disabled_globals = { "dofile", "loadfile", "require", "loadlib", "getfenv", "newproxy" }
D.mta_globals_both = { "root", "resource", "resourceRoot", "resourceName", "source", "this", "eventName", "sourceResource", "sourceResourceRoot", "sourceTimer", "exports", "inspect" }
-- `client` exists in a remotely triggered event; user / requestHeaders / form / cookies / hostname / url are set by CResource::HandleRequestCall (mtasa-blue Server/mods/deathmatch/logic/CResource.cpp)
-- while an exported function runs for an HTTP request (call interface), and are nil otherwise
D.mta_globals_server = { "client", "user", "requestHeaders", "form", "cookies", "hostname", "url" }
D.mta_globals_client = { "guiRoot", "localPlayer" }

-- library fields that do NOT exist in MTA's Lua 5.1 (or are disabled): flagged when used as  table.unpack  etc.
D.bad_fields = {
	table = { "unpack", "pack", "move", "remove_all" },
	string = { "pack", "unpack", "packsize" },
	math = { "type", "tointeger", "ult", "maxinteger", "mininteger" },
	os = { "execute", "rename", "remove", "exit", "getenv", "tmpname", "setlocale" },
	coroutine = { "close", "isyieldable" },
	debug = {},
}
-- whole globals that exist in LuaJIT / Lua 5.2+ but not in MTA
D.bad_globals = { "bit", "bit32", "jit", "package", "io", "goto", "table.unpack" }

return D
