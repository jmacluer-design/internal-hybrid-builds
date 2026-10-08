---------------------------------------------------------------------------
-- The SkateGM gamemode: everyone is in Skater mode, all the time. Built on
-- Sandbox (its spawn menu, saves and tools stay for building parks), but
-- you can't switch back to a normal Garry's Mod player. If Skater mode
-- can't start for someone (no module, no game data...), they spectate and
-- are told why.
---------------------------------------------------------------------------
DeriveGamemode("sandbox")

GM.Name = "SkateGM"
GM.Author = "SkateGM"
GM.IsSkateGM = true

SKATEGM_GM = SKATEGM_GM or {}
SKATEGM_GM.NET_START = "skategm_gm_start"   -- server -> client: get into Skater mode
SKATEGM_GM.NET_FAILED = "skategm_gm_failed" -- client -> server: couldn't (why)
SKATEGM_GM.NET_RETRY = "skategm_gm_retry"   -- client -> server: try again
SKATEGM_GM.START_TIMEOUT = 120          -- seconds to get skating (loading included) before it counts as failed
