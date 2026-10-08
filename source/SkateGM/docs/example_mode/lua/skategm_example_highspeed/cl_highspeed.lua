local mode = HIGHSPEED.mode
local C = { state = { phase = "idle" }, nextSend = 0 }
HIGHSPEED.client = C

mode:OnState(function(st) C.state = st end)

mode:OnChat(function(words)
	if words[1] == "start" then mode:Send({ cmd = "start" }) return true end
	return false
end)

hook.Add("Think", "skategmx_highspeed", function()
	if C.state.phase ~= "on" or RealTime() < C.nextSend then return end
	local api = SKATEGM_MODES.API()
	if not (api and api.IsSkating() and api.Speed) then return end
	C.nextSend = RealTime() + 0.25
	mode:Send({ cmd = "speed", v = api.Speed() })
end)

hook.Add("HUDPaint", "skategmx_highspeed", function()
	local st = C.state
	if st.phase ~= "on" then return end
	draw.SimpleText(string.format("HIGH SPEED  %ds", math.ceil(st.left or 0)), "DermaLarge", ScrW() / 2, 40, color_white, TEXT_ALIGN_CENTER)
	for i, e in ipairs(st.top or {}) do
		draw.SimpleText(string.format("%d. %s  %.1f m/s", i, e.name, e.speed), "DermaDefault", ScrW() / 2, 70 + i * 18, color_white, TEXT_ALIGN_CENTER)
	end
end)

mode:Host({
	description = "fastest in " .. HIGHSPEED.DURATION .. " seconds wins",
	options = {},
	start = function() mode:Send({ cmd = "start" }) end,
})

