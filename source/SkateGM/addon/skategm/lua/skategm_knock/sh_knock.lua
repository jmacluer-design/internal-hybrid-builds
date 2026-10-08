KNOCK = KNOCK or {}
KNOCK.NET = "skategm_knock"
KNOCK.CLASSES = { prop_physics = true, prop_physics_multiplayer = true, prop_physics_respawnable = true }
KNOCK.FLAG, KNOCK.MASS = "SkateGMKnock", "SkateGMMass"
KNOCK.COOLDOWN = 0.3     -- seconds before the same prop can be knocked again
KNOCK.MAX_SPEED = 4000   -- units/s a knock can send a prop (well past a sprinting skater)
KNOCK.SLACK = 150        -- how far (units) the server lets the skater be from the prop it says it hit
KNOCK.BOARD_PAD, KNOCK.BODY_PAD = 6, 10

local flags = bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY)
KNOCK.cvOn = CreateConVar("skategm_knock_props", "1", flags, "1 = skating into light, loose props knocks them over (they aren't solid to the skater)", 0, 1)
KNOCK.cvMass = CreateConVar("skategm_knock_mass", "150", flags, "Heaviest prop (kg) a skater knocks over; heavier ones stay solid", 1, 50000)

-- how much speed the skater loses ploughing through a prop this heavy (0..1)
function KNOCK.SpeedLoss(mass) return math.Clamp((tonumber(mass) or 0) / 400, 0.02, 0.35) end
