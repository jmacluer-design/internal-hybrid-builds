---------------------------------------------------------------------------
-- The original InfMap, server side: ground for the chunks around a skater.
-- Maps that build their collision per chunk do it when InfMap reports a
-- player arriving in a chunk (its PropUpdateChunk hook) and remove it once
-- nobody is there - so the ground of the next chunk only appears after
-- you've crossed into it, and a skater at speed drops through the gap.
-- For every skater we report the same arrival for all 8 chunks around
-- theirs (InfMap's own hook, as InfMap would: the map builds them like for
-- any player), so the ground is there a whole chunk ahead, loaded in one go
-- rather than at each border. A chunk no longer around them is let go
-- (reported left: the map tidies it away if nobody else is there) only after
-- IMS.KEEP seconds, so skating back and forth over a border doesn't build
-- and throw away the same chunks. The ones wanted are reported again every
-- IMS.REFRESH seconds: a map drops a chunk when the last player in it leaves,
-- even one we asked for. Nothing here knows any particular map.
---------------------------------------------------------------------------
SkateGM = SkateGM or {}
local IMS = {}
SkateGM.infmapServer = IMS
IMS.EVERY = 0.5   -- seconds between looks
IMS.KEEP = 12     -- seconds a chunk no longer around a skater is kept
IMS.REFRESH = 5   -- seconds between reports of the chunks still wanted
IMS.asked = IMS.asked or {} -- [ply] = { [key] = { chunk = c, at = last wanted, told = last reported } }

function IMS.Active()
	if not (InfMap and InfMap.chunk_size and hook and hook.Run) then return false end
	local map = game and game.GetMap and game.GetMap():lower() or ""
	return map:match("^[^_]+_infmap") ~= nil
end

local function Key(c) return string.format("%d,%d,%d", c.x, c.y, c.z) end

-- the 8 chunks around ply's
function IMS.Wanted(ply)
	local c = ply.CHUNK_OFFSET
	if not c then return {} end
	local out = {}
	for dx = -1, 1 do
		for dy = -1, 1 do
			if dx ~= 0 or dy ~= 0 then
				local n = Vector(c.x + dx, c.y + dy, c.z)
				out[Key(n)] = n
			end
		end
	end
	return out
end

function IMS.Think(now)
	if not IMS.Active() then return end
	now = now or (CurTime and CurTime()) or 0
	for _, ply in ipairs(player.GetAll()) do
		local mine = IMS.asked[ply] or {}
		IMS.asked[ply] = mine
		local here = ply.CHUNK_OFFSET
		local hereKey = here and Key(here)
		-- (the chunk I'm in is the map's own business now)
		if hereKey then mine[hereKey] = nil end
		local want = (ply.SkateGM and here) and IMS.Wanted(ply) or {}
		for key, chunk in pairs(want) do
			local m = mine[key]
			if not m then
				mine[key] = { chunk = chunk, at = now, told = now }
				hook.Run("PropUpdateChunk", ply, chunk, here)
			else
				m.at = now
				if now - m.told >= IMS.REFRESH then
					m.told = now
					hook.Run("PropUpdateChunk", ply, chunk, here)
				end
			end
		end
		for key, m in pairs(mine) do
			if not want[key] and now - m.at >= IMS.KEEP then
				mine[key] = nil
				if here then hook.Run("PropUpdateChunk", ply, here, m.chunk) end
			end
		end
	end
	for ply in pairs(IMS.asked) do if not IsValid(ply) then IMS.asked[ply] = nil end end
end

if timer and timer.Create then timer.Create("skategm_infmap_ahead", IMS.EVERY, 0, function() IMS.Think() end) end
