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

T.test("the phone docs match the code: the ACL block is the snippet file, the entry URL, the steps, the security notes, the three options and what is unverified", function()
	local snippet = read(H.mta .. "/tools/acl_phone_snippet.xml")
	local n = 0
	for line in snippet:gmatch("[^\n]+") do
		local t = line:gsub("^%s+", ""):gsub("%s+$", "")
		if t ~= "" and not t:find("^<!%-%-") and not t:find("^%s*Everyone") and t:find("^<") and not t:find("%-%->$") then
			n = n + 1
			T.truthy(readme:find(t, 1, true), "the README's ACL block has the line: " .. t)
		end
	end
	T.gt(n, 10, "checked the lines of the ACL snippet")
	for _, right in ipairs({ "resource.outbreak.http", "resource.outbreak.phone_view", "resource.outbreak.phone_control" }) do T.truthy(snippet:find(right, 1, true), "snippet grants " .. right) end
	local sec = readme:match("## 3a%. Phone(.-)\n## 4%. Controls")
	T.truthy(sec, "section 3a exists")
	for _, word in ipairs({ "http://<tailscale-ip>:22005/outbreak/", "phone_acl.sh", "addaccount", "chgpass", "delaccount", "Add to Home Screen", "tailscale serve", "X-Outbreak-Phone", "phoneApi", "401", "download=\"false\"",
		"Do not put a phone account in the `Admin` group", "never run on a physical phone", "Unverified", "phone_e2e.sh", "Net.do_order", "view-only", "PHONE.md", "no GTA" }) do
		T.truthy(sec:find(word, 1, true) or readme:find(word, 1, true), "section 3a mentions " .. word)
	end
	local phone = read(H.mta .. "/PHONE.md")
	for _, word in ipairs({ "Sunshine", "Moonlight", "hostkit/README.md", "Unverified", "not run", "Tailscale", "tailscale ping", "02-install-streaming.ps1", "47990" }) do T.truthy(phone:find(word, 1, true), "PHONE.md mentions " .. word) end
	local f = io.open(H.mta .. "/../../../hostkit/README.md", "rb")
	T.truthy(f, "PHONE.md points at a file that exists (hostkit/README.md)")
	if f then f:close() end
	for _, file in ipairs({ "tools/phone_e2e.sh", "tools/phone_acl.sh", "tools/acl_phone_snippet.xml", "tests/phone_e2e.mjs", "tests/phone_test.lua", "tools/gen_phone_icons.py" }) do
		local g = io.open(H.mta .. "/" .. file, "rb")
		T.truthy(g, file .. " exists")
		if g then g:close() end
	end
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
	T.ge(n, 3)
	for _, repo in ipairs({ "rxi/json.lua", "multitheftauto/mtasa-resources", "TitansProductions/TP-Advanced-Zombies", "Blumlaut/RottenV", "NullSystemWorks/mtadayz", "mta-resources/deadwalkers",
		"multitheftauto/mtasa-blue", "overextended/ox_lib" }) do
		T.truthy(third:find(repo, 1, true), "THIRD_PARTY.md names " .. repo)
	end
	T.truthy(third:find("Copyright (c) 2020 rxi", 1, true), "rxi/json.lua MIT notice kept")
	T.truthy(read(H.res .. "/shared/json_decode.lua"):find("Copyright (c) 2020 rxi", 1, true), "and in the file itself")
end)

T.test("the PRIVATE USE ONLY blocks: every BORROWED-PRIVATE block is closed, listed by tools/list_private_blocks.sh and a row of THIRD_PARTY.md; the README warns; --check fails while any exists", function()
	local function sh(cmd)
		local p = io.popen(cmd .. ' 2>&1; echo "EXIT:$?"')
		local out = p:read("*a")
		p:close()
		return tonumber(out:match("EXIT:(%d+)%s*$")), out
	end
	local script = H.tools .. "/list_private_blocks.sh"
	local code, out = sh("sh " .. script)
	T.eq(code, 0, out)
	local blocks, files = {}, {}
	for loc, src in out:gmatch("\n  ([%w_/%.]+:%d+%-%d+)%s+([^\n]+)") do blocks[#blocks + 1] = { loc = loc, src = src } end
	T.ge(#blocks, 15, "the blocks are listed")
	T.falsy(out:find("UNCLOSED", 1, true) or out:find("END without", 1, true), "every block is closed: " .. out)
	local priv = third:match("## PRIVATE USE ONLY %(no licence upstream%)(.-)\n## ")
	T.truthy(priv, "THIRD_PARTY.md has the PRIVATE USE ONLY section")
	T.truthy(priv:find("NEVER share", 1, true), "and its warning")
	for _, b in ipairs(blocks) do
		local file = b.loc:match("^([^:]+):")
		files[file] = true
		local repo, path = b.src:match("^(%S+/%S+)/slothbot/(%S+%.lua)") 
		local dayz = b.src:match("^NullSystemWorks/mtadayz/DayZ/tables/(%S+%.lua)")
		T.truthy(priv:find(file, 1, true), "THIRD_PARTY private section names " .. file)
		T.truthy((path and priv:find(path, 1, true)) or (dayz and priv:find(dayz, 1, true)), "and the source file of the block at " .. b.loc .. ": " .. b.src)
		T.truthy(b.src:find("NullSystemWorks/mtadayz", 1, true) or b.src:find("mta-resources/deadwalkers", 1, true), "the source is one of the two unlicensed repos: " .. b.src)
	end
	local n = 0
	for _ in pairs(files) do n = n + 1 end
	T.ge(n, 5, "blocks in several files")
	local code2, out2 = sh("sh " .. script .. " --check")
	T.eq(code2, 1, "--check exits 1 while blocks exist")
	local code3, out3 = sh("sh " .. script .. " --files")
	T.eq(code3, 0); T.truthy(out3:find("client/driver.lua", 1, true))
	for _, w in ipairs({ "PRIVATE USE ONLY", "NEVER REDISTRIBUTE", "list_private_blocks.sh", "BORROWED-PRIVATE", "NullSystemWorks/mtadayz", "mta-resources/deadwalkers" }) do
		T.truthy(readme:find(w, 1, true), "the README says " .. w)
	end
	T.truthy(readme:find("real_server_smoke.sh", 1, true), "the README documents the real-server smoke test")
	T.truthy(read(H.tools .. "/real_server_smoke.sh"):find("Resources: 1 loaded, 0 failed", 1, true), "and the script asserts the load line")
	-- the stripped marker never hides in a licence-clean file: no BORROWED-PRIVATE text outside these blocks and the warnings that say so
	local p = io.popen('cd "' .. H.res .. '" && grep -rl "BORROWED-PRIVATE" --include=*.lua . | LC_ALL=C sort')
	local with_word = {}
	for f in p:lines() do with_word[#with_word + 1] = f:gsub("^%./", "") end
	p:close()
	for _, f in ipairs(with_word) do T.truthy(files[f] or f == "server/zombies.lua" or f == "client/driver.lua" or f == "server/peds.lua", f .. " mentions BORROWED-PRIVATE but has no block") end
end)
