SKATEGM_STATIONS = {
	{ "Fluid (instrumental hip hop)", "https://ice2.somafm.com/fluid-128-mp3" },
	{ "Indie Pop Rocks", "https://ice2.somafm.com/indiepop-128-mp3" },
	{ "Underground 80s", "https://ice2.somafm.com/u80s-128-mp3" },
	{ "Metal Detector", "https://ice2.somafm.com/metal-128-mp3" },
	{ "Beat Blender (deep house)", "https://ice2.somafm.com/beatblender-128-mp3" },
	{ "DEF CON Radio", "https://ice2.somafm.com/defcon-128-mp3" },
	{ "PopTron", "https://ice2.somafm.com/poptron-128-mp3" },
	{ "Dub Step Beyond", "https://ice2.somafm.com/dubstep-128-mp3" },
	{ "Vaporwaves", "https://ice2.somafm.com/vaporwaves-128-mp3" },
	{ "Groove Salad (chill)", "https://ice2.somafm.com/groovesalad-128-mp3" },
}

function SKATEGM_STATIONS_LOAD(text)
	local list = {}
	for line in (text or ""):gmatch("[^\r\n]+") do
		local name, url = line:match("^%s*([^|#][^|]-)%s*|%s*(https?://%S+)%s*$")
		if name and url then list[#list + 1] = { name, url } end
	end
	return list
end

if SERVER and file and file.Read then
	local custom = SKATEGM_STATIONS_LOAD(file.Read("skategm/stations.txt", "DATA"))
	if #custom > 0 then SKATEGM_STATIONS = custom end
end
