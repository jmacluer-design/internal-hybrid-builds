# Outbreak (working title): GTA world x colony manager x zombie survival

Private, non-commercial, runs on the owner's own PC with their own copy of the game. Nothing here is hosted publicly.
Status: PLAN ONLY. Nothing below has been run on a real GTA V install. Research date 2026-10-10; sources marked
[P] primary / [S] secondary / [A] anecdote / [N] not found (from the research pass; re-verify before relying on them).

## Concept
Third-person survival (needs, bleeding, infection, noise-attracted zombies, scavenging, carry weight, barricades) with a
key that lifts the camera overhead into a colony manager (survivors with needs and work priorities, stockpile, blueprint
building, a "storyteller" that schedules hordes and raids). Gangs are the factions. Vehicles are the scavenging range.
Win: hold the base and escape (airport / boat). Original names, art and rules only (see Guardrails).

## Platform decision: FiveM on GTA V **Legacy**, local-only server (`sv_lan`)
| Why | Evidence |
|---|---|
| Only option with an explicit Rockstar licence and a private-server clause | Creator PLA, updated 2026-09-10: custom servers authorized (2.3), user devices (2.1), Rockstar may take adverse action vs user/account/server on breach (7.2) [P] |
| Real "GTA graphics" | ReShade + NaturalVision/QuantV on Legacy [S]. San Andreas stays 2004-era even with ENB |
| UI is HTML | NUI = full Chromium UI (`SendNuiMessage`, `SetNuiFocus`): the colony UI and inventory are web pages [P] |
| Scripting | Lua 5.4 / JS / TS / C# [P] |
| Not chosen | Enhanced (FiveM early access since 2026-07-21, closed-source parts, packs unverified), MTA:SA (peds hard-capped at 140, ReShade blocked, Take-Two DMCA'd the repo Dec 2025 then restored), SA single-player CLEO/ASI (weak UI/scale), V single-player ScriptHookVDotNet (viable fallback: weaker UI) |
SA Definitive Edition (Unreal Engine 4) is the one SA that takes UEVR for VR (free Holydh plugin, Steam) [S], but it is a different
modding world and not a base for this plan.

## Guardrails (design, not legal advice)
Rockstar's Mod Guidelines (2026-09, read via secondary reporting [S]): no story characters/missions, no mixing assets between Rockstar
titles, no reused voice lines, no third-party IP, non-commercial. So: no CJ/Michael/Franklin/Trevor, no San Andreas assets in V, no
RimWorld / Project Zomboid names or art (call it Outbreak), no money mechanics. Keep a separate mod copy of the game; never join GTA Online
with mods; consider a separate Rockstar account for the modded install. Risk reading: low, not zero.

## Architecture (so most of it is testable off-PC)
1. `sim/` pure Lua, zero game calls: needs/moods, wounds+infection, job queue (haul/build/guard/scavenge), stockpiles, blueprints,
   storyteller (threat points from wealth + time, three pacing curves), horde abstraction (off-screen groups materialize near the player,
   Cataclysm-style), loot tables, seeded RNG. Unit-tested under LuaJIT here (same method as the GMod addon: 97/97 against a mock).
2. `adapter/` thin FiveM layer: ped spawn/tasks, relationship groups, cameras, objects, KVP persistence. Written against the natives
   list in `/home/user/citizenfx/fivem/ext/natives/natives_stash/gta_universal.lua`. NOT testable here: first real test = your PC.
3. `ui/` NUI pages (inventory, colony overview, build menu, storyteller log). Tested here in headless Chromium with mocked messages.
Persistence: KVP natives; save format versioned from day one.

## Phases
| # | Deliverable | Verified where |
|---|---|---|
| 0 | Host ready: Windows PC with GTA V Legacy + FiveM, `sv_lan` local server boots, empty resource loads | your PC (hostkit) |
| 1 | Survival slice: needs, bleeding/infection, loot, NUI inventory, 20-40 zombies on a hostile relationship group with noise/gunshot attraction | sim+UI here; adapter on PC |
| 2 | Colony slice: overhead camera with click-select, 3-6 colonist peds, haul/build/guard queue, stockpile rectangle, ~20 persisted blueprint props | same |
| 3 | Storyteller + factions: wealth/time threat points -> hordes and gang raids, gangs as relationship-group factions | same |
| 4 stretch | research tree, mood breaks, skills, 100+ zombies, 20+ colonists on navmesh, Enhanced | research-grade |
Research estimate: phases 1-3 are about 40-60 part-time hours with an AI pair; phase 4 is a stretch.

## Building blocks (licences matter: GPL means share-alike if reused)
FiveM: ox_inventory (GPL-3.0), ox_lib (LGPL-3.0), ox_core (LGPL-3.0), qbx_core (GPL-3.0), RottenV (MIT, zombies+needs, stale 2024),
TP-Advanced-Zombies (Apache-2.0, unsupported), Dislaik/zombieoutbreak (GPL-3.0, archived), 7_popmanager (GPL-3.0). No open RTS-camera,
colony-NPC or base-building framework was found: those we write. Design references already pulled locally: Cataclysm-DDA
(`src/horde_map.cpp`, `basecamp.cpp`, `faction_camp.cpp`, `mission_companion.cpp`; CC BY-SA 3.0: learn the design, re-implement), GrandTheftMinecraft
(`gta/src/mobs.cpp`, `world.cpp`, `objects.cpp`: relationship groups, object budgets, saving), `ryankopf/colony/src/needs.rs`, `openfw-game/crawling-agony/gdd.md`.

## Open questions (only the PC can answer)
- Does the FiveM client need a Cfx.re login / internet / Rockstar launcher login with `sv_lan`? [N]
- GTA V Legacy ped pool size under FiveM (forum anecdote only); object budget (~1500 script objects warning from GrandTheftMinecraft) [A]
- Whether any Rockstar account action applies to local-only FiveM use [N]
- Is GTA V owned on PC, and is it Legacy or Enhanced?
