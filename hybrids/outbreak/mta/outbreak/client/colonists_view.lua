-- client/colonists_view.lua : the colonists the owner's client can see, for picking and drawing. The server creates the colonist peds and tags each with the element data "ob:cid"
-- (the colonist id); the client lists the streamed-in peds that carry it. Element data is only used for display here: a client can write element data, so the server never reads it back.
-- Written here; nothing borrowed.
local V = {}

-- { { ped, id }, ... } for every living, streamed-in colonist ped
function V.list()
	local out = {}
	for _, ped in ipairs(getElementsByType("ped", resourceRoot, true)) do
		local id = getElementData(ped, "ob:cid")
		if type(id) == "string" and not isPedDead(ped) then out[#out + 1] = { ped = ped, id = id } end
	end
	return out
end

return V
