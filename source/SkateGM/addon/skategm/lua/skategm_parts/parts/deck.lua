local P = SKATEGM_PARTS
-- a flat platform: joins quarter pipes, banks and other decks as high
local sizes = {}
for _, h in ipairs({ 24, 48, 72, 96, 128 }) do
	for _, w in ipairs({ 128, 256 }) do
		sizes[#sizes + 1] = { key = h .. "x" .. w, title = h .. " high, " .. w .. " wide", h = h, w = w }
	end
end
P.Family({
	id = "deck", title = "Deck", order = 20, surface = "wood", category = "SkateGM Platforms",
	info = "A flat platform, 128 long. Its edges snap to quarter pipes, banks and decks as high.",
	sizes = sizes,
	build = function(s) return { P.Box(0, 0, 0, 128, s.w, s.h) } end,
})
