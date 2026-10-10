-- client/ground.lua : the owner's client is the only place that knows where the ground is (getGroundPosition needs the collision the client has loaded), so once a second it samples
-- the ground under the player and under the server's peds and objects that are streamed in, and reports the ones whose height is off (a ped that fell through the map, an object
-- created at the base height on sloping ground) as outbreak:ground samples { e = element, x, y, z = ground, b = height of the element origin above the ground }. The server keeps a height map
-- for new spawns and re-seats the listed elements (server/ground.lua validates every sample and only acts on elements it created).
-- A getGroundPosition result of 0 means "nothing loaded here" and is never reported. Written here; nothing borrowed.
local ctx = require("client.ctx")
local NET = require("shared.mta_net")

local G = { cursor = 1, stats = { sent = 0, samples = 0 } }
local cfg = ctx.cfg

-- getGroundPosition casts a ray DOWN from z, so for something that fell below the ground the cast must start higher: just above the base height (never below the element itself)
local function sample_ground(x, y, z)
	local gz = getGroundPosition(x, y, math.max(z + 3.0, ctx.origin.z + 30.0))
	if type(gz) == "number" and gz ~= 0 then return gz end
	return nil
end

function G.step()
	local out = {}
	-- the player: a plain sample (no element) so new spawns near the player get the right height
	local px, py, pz = getElementPosition(localPlayer)
	local pg = sample_ground(px, py, pz)
	if pg then out[#out + 1] = { x = px, y = py, z = pg } end
	-- a round-robin slice of the server's streamed-in peds and objects
	local all = {}
	for _, ped in ipairs(getElementsByType("ped", resourceRoot, true)) do all[#all + 1] = { e = ped, b = 1.0, ped = true } end
	for _, obj in ipairs(getElementsByType("object", resourceRoot, true)) do all[#all + 1] = { e = obj, b = false } end
	local n = #all
	if n > 0 then
		local slice = math.min(n, cfg.ground_batch)
		for i = 1, slice do
			local item = all[(G.cursor + i - 2) % n + 1]
			local e = item.e
			local ex, ey, ez = getElementPosition(e)
			local gz = sample_ground(ex, ey, ez)
			if gz then
				local b = item.b
				if not b then b = getElementDistanceFromCentreOfMassToBaseOfModel(e) or 0.0 end
				if math.abs(ez - (gz + b)) > 0.6 and not (item.ped and isPedDead(e)) then out[#out + 1] = { e = e, x = ex, y = ey, z = gz, b = b } end
			end
		end
		G.cursor = (G.cursor + slice - 1) % n + 1
	end
	if #out > 0 then
		G.stats.sent = G.stats.sent + 1
		G.stats.samples = G.stats.samples + #out
		triggerServerEvent(NET.ground, resourceRoot, out)
	end
end

function G.start() ctx.loop("ground", cfg.ground_ms, G.step) end

return G
