-- README.md / THIRD_PARTY.md must not drift from the code: every command, setting, remote event, key and MTA function the resource uses is documented, the numbers quoted are the configured ones,
-- and every `borrowed:` mark in the sources is a row in THIRD_PARTY.md.
local T, H = ...
T.group("docs")
local interp = (arg and arg[-1]) or "lua5.4"

local function read(path)
	local f = assert(io.open(path, "rb"), "cannot open " .. path)
	local s = f:read("*a")
	f:close()
	return s
end
local readme = read(H.mta .. "/README.md")
local third = read(H.mta .. "/THIRD_PARTY.md")
local meta = read(H.res .. "/meta.xml")
local Config = require("shared.mta_config")
local NET = require("shared.mta_net")

T.test("every /outbreak_* command is in the README command table and in its ACL snippet", function()
	local commands = {}
	for name in read(H.res .. "/server/commands.lua"):gmatch('command%("(outbreak_[%w_]+)"') do commands[#commands + 1] = name end
	T.gt(#commands, 15, "found the server commands")
	for _, name in ipairs(commands) do
		T.truthy(readme:find("/" .. name, 1, true), "command table mentions /" .. name)
		T.truthy(readme:find('<right name="command.' .. name .. '" access="true"/>', 1, true), "the ACL snippet grants command." .. name)
	end
	for name in read(H.res .. "/client/main.lua"):gmatch('addCommandHandler%("(outbreak_[%w_]+)"') do
		T.truthy(readme:find("/" .. name, 1, true), "client command /" .. name .. " is documented")
	end
end)

T.test("every setting of meta.xml is documented with its default, the quoted budget numbers are the configured ones", function()
	local n = 0
	for name, value in meta:gmatch('<setting name="([%w_]+)" value="([^"]*)"') do
		n = n + 1
		T.truthy(readme:find("| `" .. name .. "` |", 1, true), "settings table has " .. name)
		if value ~= "" then T.truthy(readme:find("| `" .. name .. "` | " .. value, 1, true) or readme:find("| `" .. name .. "` | `" .. value .. "`", 1, true), "default of " .. name .. " is " .. value) end
	end
	T.ge(n, 19)
	local p = Config.peds
	T.eq(Config.server.max_materialized, 60); T.eq(p.max_peds, 96); T.eq(p.pool_guard, 120); T.eq(p.max_objects, 400)
	T.truthy(readme:find("60 hostile peds + 16 colonists + 4 traders + the players + up to 12 waiting corpses = 96", 1, true), "the ped budget sum is quoted")
	T.eq(p.max_colonist_peds, 16)
end)

T.test("every remote event and the local browser event are listed; every key bound in the client is in the controls table", function()
	for _, name in ipairs(NET.TO_CLIENT) do T.truthy(readme:find(name, 1, true), "README lists " .. name) end
	for _, name in ipairs(NET.TO_SERVER) do T.truthy(readme:find(name, 1, true), "README lists " .. name) end
	T.truthy(readme:find(NET.browser .. "`", 1, true), "README lists the local event")
	T.truthy(readme:find("**" .. Config.client.colony_key .. "**", 1, true), "colony key")
	T.truthy(readme:find("**" .. Config.client.inventory_key:upper() .. "**", 1, true), "inventory key")
	T.truthy(readme:find("**" .. Config.client.interact_key:upper() .. "**", 1, true), "interact key")
	local main = read(H.res .. "/client/main.lua")
	T.truthy(main:find("bindKey(ctx.cfg.colony_key", 1, true) and main:find("bindKey(ctx.cfg.inventory_key", 1, true) and main:find("bindKey(ctx.cfg.interact_key", 1, true), "the three binds the table documents exist")
	-- built-in events the code handles (names only), documented in section 11
	local seen = {}
	for _, dir in ipairs({ "server", "client" }) do
		local p = io.popen('cd "' .. H.res .. '/' .. dir .. '" && cat *.lua')
		local text = p:read("*a")
		p:close()
		for ev in text:gmatch('"(on[A-Z][%w]+)"') do seen[ev] = true end
	end
	local n = 0
	for ev in pairs(seen) do n = n + 1; T.truthy(readme:find("`" .. ev .. "`", 1, true), "README lists the built-in event " .. ev) end
	T.gt(n, 15)
end)

T.test("the function table equals what function_check finds in the code (names and sides), and says how many", function()
	local p = io.popen(interp .. " " .. H.tools .. "/function_check.lua --markdown 2>/dev/null; echo \"EXIT:$?\"")
	local out = p:read("*a")
	p:close()
	local code = tonumber(out:match("EXIT:(%d+)%s*$"))
	if code == 2 then T.note("function_check could not run here (no mtasa-blue clone or luac5.4): README function table not compared"); return end
	T.eq(code, 0, out)
	local want, got = {}, {}
	for name, side in out:gmatch("| `([%w_]+)` | (%a+) |") do want[name] = side end
	local block = readme:match("<!%-%- functions:begin.-%-%->(.-)<!%-%- functions:end %-%->")
	T.truthy(block, "the README has the generated block")
	for name, side in block:gmatch("| `([%w_]+)` | (%a+) |") do got[name] = side end
	local nw, ng = 0, 0
	for name, side in pairs(want) do nw = nw + 1; T.eq(got[name], side, "README side of " .. name) end
	for name in pairs(got) do ng = ng + 1; T.truthy(want[name], "README lists " .. name .. " but the code does not use it") end
	T.eq(nw, ng)
	T.truthy(readme:find("**" .. nw .. "** distinct functions", 1, true), "the README says " .. nw .. " distinct functions")
end)

T.test("the README has the sections the brief asks for: install, Tailscale, keybinds, unverified list, graphics research with links, mock limits", function()
	for _, h in ipairs({ "## 2. Install", "## 3. Tailscale", "## 4. Controls", "## 10. Unverified until it runs in the real game", "## 8. Graphics", "## 9. Tests and what the mocks cannot prove", "## 11. Every MTA function used" }) do
		T.truthy(readme:find(h, 1, true), "section " .. h)
	end
	local links = 0
	local graphics = readme:match("## 8%. Graphics(.-)\n## 9%.")
	for _ in graphics:gmatch("%]%(https://[^%)]+%)") do links = links + 1 end
	T.ge(links, 8, "the graphics section links its sources")
	for _, word in ipairs({ "ENB", "ReShade", "SilentPatch", "SkyGfx", "unconfirmed", "DMCA", "Take-Two" }) do T.truthy(graphics:find(word, 1, true), "graphics section covers " .. word) end
	T.truthy(readme:find("server cannot steer a ped", 1, true) or readme:find("cannot steer a ped", 1, true), "the setPedControlState finding is stated up front")
	T.truthy(readme:find("server objects", 1, true), "the buildings-on-the-server deviation is stated")
end)

T.test("every `borrowed:` mark in the resource's own code is a row in THIRD_PARTY.md, and the notices of the MIT blocks are kept", function()
	local p = io.popen('cd "' .. H.res .. '" && grep -rn "borrowed:" --include=*.lua client server shared bootstrap_mta.lua | grep -v "^shared/\\(host\\|protocol\\|view\\|survival\\|util\\|json\\|raymath\\|placement\\)\\.lua"')
	local lines = p:read("*a")
	p:close()
	local n = 0
	for file, text in lines:gmatch("([^:\n]+):%d+:%s*%-%-%s*borrowed:%s*([^\n]+)") do
		n = n + 1
		local repo = text:match("([%w%-_%.]+/[%w%-_%.]+)")
		if repo and not text:find("FiveM adapter", 1, true) then T.truthy(third:find(repo, 1, true), file .. " borrows from " .. repo .. ": THIRD_PARTY.md names it") end
	end
	T.ge(n, 4)
	for _, repo in ipairs({ "rxi/json.lua", "multitheftauto/mtasa-resources", "TitansProductions/TP-Advanced-Zombies", "Blumlaut/RottenV", "NullSystemWorks/mtadayz", "mta-resources/deadwalkers",
		"multitheftauto/mtasa-blue", "overextended/ox_lib" }) do
		T.truthy(third:find(repo, 1, true), "THIRD_PARTY.md names " .. repo)
	end
	T.truthy(third:find("Copyright (c) 2020 rxi", 1, true), "rxi/json.lua MIT notice kept")
	T.truthy(read(H.res .. "/shared/json_decode.lua"):find("Copyright (c) 2020 rxi", 1, true), "and in the file itself")
end)
