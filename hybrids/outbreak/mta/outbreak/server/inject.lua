-- server/inject.lua : feeds IN events that the SERVER itself observed (a zombie bite, a death reported by onPedWasted, a scream, a horde centroid) into the sim host. They take the same
-- path as events from the client (shared/host.lua on_client_event: sanitize_in, rate limit, world:handle) minus the network. Written here; nothing borrowed.
local ctx = require("server.ctx")

local I = { stats = { sent = 0, refused = 0 } }

function I.event(ev)
	local host = ctx.host
	if not host or not host.world then I.stats.refused = I.stats.refused + 1; return false end
	local ok = host:on_client_event(ev)
	if ok then I.stats.sent = I.stats.sent + 1 else I.stats.refused = I.stats.refused + 1 end
	return ok
end

return I
