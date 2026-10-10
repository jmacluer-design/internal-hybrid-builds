-- data/districts.lua : abstract map districts for expeditions, loot and noise.
--   x, y        centre in sim coordinates (base is the origin)
--   danger      1 (quiet) .. 5 (deadly): loot quality tilt, ambush risk, zombie density
--   travel      one-way minutes by a van at speed 1.0
--   loot        loot table id (data/loot.lua)       radius = size in world units
--   zombies     typical number of walkers met on a run (before danger scaling)
local D = {}

local function d(id, t) t.id = id; D[id] = t end

d("orchard", { name = "Orchard Heights", kind = "residential", x = 520, y = 300, radius = 260, danger = 1, travel = 15, loot = "residential", zombies = 5 })
d("old_town", { name = "Old Town", kind = "mixed", x = -420, y = 380, radius = 240, danger = 2, travel = 20, loot = "commercial", zombies = 9 })
d("mill_flats", { name = "Mill Flats", kind = "residential", x = -760, y = -520, radius = 300, danger = 2, travel = 25, loot = "residential", zombies = 11 })
d("millworks", { name = "Millworks Yard", kind = "industrial", x = -300, y = -900, radius = 220, danger = 2, travel = 28, loot = "industrial", zombies = 12 })
d("precinct", { name = "Eastgate Precinct", kind = "police", x = 760, y = 640, radius = 180, danger = 3, travel = 32, loot = "police", zombies = 15 })
d("dockside", { name = "Dockside Row", kind = "industrial", x = -1150, y = 820, radius = 320, danger = 3, travel = 35, loot = "industrial", zombies = 16 })
d("depot", { name = "Crossroads Depot", kind = "fuel", x = 260, y = -640, radius = 160, danger = 2, travel = 22, loot = "garage", zombies = 10 })
d("hollow_mall", { name = "Hollow Mall", kind = "commercial", x = 980, y = -740, radius = 280, danger = 3, travel = 40, loot = "commercial", zombies = 20 })
d("saint_anne", { name = "Saint Anne Clinic", kind = "medical", x = 340, y = 1180, radius = 200, danger = 4, travel = 45, loot = "medical", zombies = 24 })
d("foundry", { name = "Foundry Quarter", kind = "industrial", x = -1500, y = -300, radius = 330, danger = 4, travel = 50, loot = "industrial", zombies = 26 })
d("reservoir", { name = "Reservoir Hills", kind = "rural", x = 1700, y = 900, radius = 400, danger = 1, travel = 55, loot = "rural", zombies = 6 })
d("airfield", { name = "Airfield Road", kind = "military", x = 1900, y = -1500, radius = 380, danger = 5, travel = 70, loot = "military", zombies = 34 })

return D
