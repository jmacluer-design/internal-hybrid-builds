-- client/relations.lua : relationship groups. Zombies hate the player and the colony; the colony is "companion" to the player; each gang is its
-- own faction group (hostile raiders, neutral-to-friendly traders). Relation levels (GTA): 0 companion, 1 respect, 2 like, 3 neutral, 4 dislike, 5 hate.
--
-- borrowed: Blumlaut/RottenV client/spawners/zombiespawner.lua (MIT): AddRelationshipGroup("zombeez") + SetRelationshipBetweenGroups(5, ...) vs PLAYER;
--           squarerootof49/7_popmanager client.lua (GPL-3.0): the relationship-reset on resource stop (done here per group we created).
local ctx = require("client.ctx")

local R = { names = {} }

local GROUPS = { "OB_ZOMBIE", "OB_COLONY", "OB_RUSTJAW", "OB_HOLLOW_CHOIR", "OB_TALLOW", "OB_CINDER", "OB_LANTERN", "OB_TRADER" }
local FACTION_GROUP = { rustjaw = "OB_RUSTJAW", hollow_choir = "OB_HOLLOW_CHOIR", tallow = "OB_TALLOW", cinder = "OB_CINDER", lantern = "OB_LANTERN" }

local function both(level, a, b)
	SetRelationshipBetweenGroups(level, a, b)
	SetRelationshipBetweenGroups(level, b, a)
end

function R.setup()
	if #R.names > 0 then return end -- already set up (the server may greet a client twice: hello on load, hello after the NUI `ready`)
	for _, name in ipairs(GROUPS) do
		AddRelationshipGroup(name)
		ctx.rel[name] = GetHashKey(name)
		R.names[#R.names + 1] = name
	end
	local player = GetHashKey("PLAYER")
	ctx.rel.PLAYER = player
	both(5, ctx.rel.OB_ZOMBIE, player)
	both(5, ctx.rel.OB_ZOMBIE, ctx.rel.OB_COLONY)
	both(0, ctx.rel.OB_COLONY, player)
	for _, g in pairs(FACTION_GROUP) do
		both(5, ctx.rel[g], ctx.rel.OB_ZOMBIE)          -- everyone is food
		both(5, ctx.rel[g], ctx.rel.OB_COLONY)
		both(5, ctx.rel[g], player)
	end
	-- survivors we can trade with: neutral to the player and the colony, but the dead still hate them
	both(3, ctx.rel.OB_TRADER, player)
	both(3, ctx.rel.OB_TRADER, ctx.rel.OB_COLONY)
	both(5, ctx.rel.OB_TRADER, ctx.rel.OB_ZOMBIE)
	for _, g in pairs(FACTION_GROUP) do both(5, ctx.rel.OB_TRADER, ctx.rel[g]) end
	both(3, ctx.rel.OB_TALLOW, ctx.rel.OB_CINDER)
	both(3, ctx.rel.OB_RUSTJAW, ctx.rel.OB_HOLLOW_CHOIR)
end

function R.group_for_faction(faction) return ctx.rel[FACTION_GROUP[faction] or "OB_RUSTJAW"] end

function R.cleanup()
	local player = GetHashKey("PLAYER")
	for _, name in ipairs(R.names) do
		local h = ctx.rel[name]
		if h then
			SetRelationshipBetweenGroups(3, h, player) -- neutral again before the group disappears
			SetRelationshipBetweenGroups(3, player, h)
			RemoveRelationshipGroup(h)
		end
	end
	R.names = {}
end

ctx.on_cleanup("relations", R.cleanup)
return R
