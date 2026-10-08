---------------------------------------------------------------------------
-- Park saves through Garry's Mod's own saves (the spawn menu's Saves tab):
-- saving writes a normal GMod save of the whole map (gm_save), and loading
-- one (gm_load) puts every part back. The park editor's Park page lists
-- your saves for this map and the Workshop's, on the controller.
-- (GMod allows saving in singleplayer, and to admins on a server; loading
-- is for the host.)
---------------------------------------------------------------------------
if not (SKATEGM_UI and SKATEGM_UI.pad) then include("skategm_ui/cl_pad.lua") end
local P = SKATEGM_PARTS
local SV = P.saves or {}
P.saves = SV
SV.PER_PAGE = 30
SV.workshop = SV.workshop or {}
SV.info = SV.info or {}

function SV.Map() return game and game.GetMap and game.GetMap() or "" end

-- the map a .gms file was saved on: its first line, after 4 bytes
function SV.SaveMap(path)
	local f = file.Open(path, "rb", "GAME")
	if not f then return nil end
	f:Seek(4)
	local line = f:ReadLine()
	f:Close()
	return line and line:gsub("[\r\n]+$", "") or nil
end

-- my saves of this map, newest first: { name, file }
function SV.Local()
	local out, map = {}, SV.Map()
	for _, name in ipairs(file.Find("saves/*.gms", "MOD", "datedesc") or {}) do
		local path = "saves/" .. name
		if SV.SaveMap(path) == map then out[#out + 1] = { name = name:gsub("%.gms$", ""), file = path } end
		if #out >= SV.PER_PAGE then break end
	end
	return out
end

function SV.CanSave()
	if game.SinglePlayer() then return true end
	local me = LocalPlayer()
	return IsValid(me) and me:IsAdmin()
end

function SV.Save()
	if not SV.CanSave() then return false, "only the host and admins can save on a server" end
	RunConsoleCommand("gm_save", "spawnmenu")
	return true, "saved (Spawn menu > Saves has it too)"
end

function SV.Load(path)
	RunConsoleCommand("gm_load", path)
	return true
end

-- the Workshop's saves for this map (sort: "popular" or "latest")
function SV.FetchWorkshop(sort)
	local w = SV.workshop[sort] or {}
	SV.workshop[sort] = w
	if w.busy or w.ids then return w end
	w.busy = true
	if not (steamworks and steamworks.GetList) then w.busy, w.ids, w.error = false, {}, "the Workshop isn't available" return w end
	steamworks.GetList(sort, { "save", SV.Map() }, 0, SV.PER_PAGE, 0, "0", function(data)
		w.busy = false
		w.ids = data and data.results or {}
		w.total = data and data.totalresults or 0
		for _, id in ipairs(w.ids) do SV.FetchInfo(id) end
	end)
	return w
end

function SV.FetchInfo(id)
	if SV.info[id] then return SV.info[id] end
	SV.info[id] = { title = "loading..." }
	if steamworks and steamworks.FileInfo then
		steamworks.FileInfo(id, function(r)
			if r and not r.error then SV.info[id] = { title = r.title or tostring(id), owner = r.ownername } else SV.info[id] = { title = "unavailable" } end
		end)
	end
	return SV.info[id]
end

function SV.LoadWorkshop(id, done)
	if not (steamworks and steamworks.DownloadUGC) then return false end
	steamworks.DownloadUGC(id, function(name)
		if not name then if done then done(false) end return end
		SV.Load(name)
		if done then done(true) end
	end)
	return true
end

---------------------------------------------------------------------------
-- pages for the park editor's menu: { title, rows() }
---------------------------------------------------------------------------
function SV.Note(text) SV.note = { text = text, t = RealTime() } end

function SV.LocalPage()
	local page = { title = "My saves of " .. SV.Map() }
	page.rows = function()
		local rows = {}
		for _, s in ipairs(SV.Local()) do
			rows[#rows + 1] = { label = s.name, sub = "replaces everything here", aText = "Load", run = function() SV.Load(s.file) SV.Note("loading " .. s.name) end }
		end
		if #rows == 0 then rows[1] = { label = "No saves of this map yet", sub = "Park > Save the park makes one" } end
		return rows
	end
	return page
end

-- (D-pad left / right on the first row: most popular or newest)
SV.SORTS = { { "popular", "Most popular" }, { "latest", "Newest" } }
function SV.WorkshopPage(sort)
	local page = { title = "Workshop saves for " .. SV.Map(), sort = sort == "latest" and 2 or 1 }
	page.rows = function()
		local w = SV.FetchWorkshop(SV.SORTS[page.sort][1])
		local names = {}
		for i, e in ipairs(SV.SORTS) do names[i] = e[2] end
		local rows = { SKATEGM_UI.List.Choice("Show", names, function() return page.sort end, function(i) page.sort = i end) }
		if w.busy then rows[#rows + 1] = { label = "Asking the Workshop..." } return rows end
		if w.error then rows[#rows + 1] = { label = w.error } return rows end
		for _, id in ipairs(w.ids or {}) do
			local info = SV.FetchInfo(id)
			rows[#rows + 1] = { label = info.title, sub = info.owner and ("by " .. info.owner) or nil, aText = "Load", run = function()
				SV.Note("downloading " .. info.title .. "...")
				SV.LoadWorkshop(id, function(ok) SV.Note(ok and ("loading " .. info.title) or "the download failed") end)
			end }
		end
		if #rows == 1 then rows[2] = { label = "No Workshop saves for this map" } end
		return rows
	end
	return page
end

function SV.Rows()
	return {
		{ label = "Save the park", sub = SV.CanSave() and "a Garry's Mod save of the map" or "host and admins only", run = function()
			local _, msg = SV.Save()
			SV.Note(msg)
		end },
		{ label = "Load one of my saves", sub = "this map's", page = SV.LocalPage },
		{ label = "Workshop saves for this map", sub = "browse and load", page = function() return SV.WorkshopPage("popular") end },
	}
end
