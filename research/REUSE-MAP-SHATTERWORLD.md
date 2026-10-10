# Shatterworld reuse map: food / mobs / crafting / town hub
Survey 2026-10-10 of the 42 repos in /home/user (matches SOURCES.md; the "~60" estimate was high) plus 5 repos cloned for this task. Private, non-commercial use. Counts below were measured by parsing the files, paths are relative to /home/user/<owner>/<repo>. Not legal advice.

## (a) Summary and take-these-first
Nothing on disk is a drop-in for a three.js game: the useful material is **data schemas and numbers** (CC BY-SA / MIT) and **small algorithms** to re-implement in JS. The biggest finds are (1) a data-driven enemy/NPC/vendor/quest format in Flare's Empyrean content (not in flare-engine, which ships only the UI mod; I cloned the data repo), (2) DwarfCorp's tag-based recipe/food/event JSON (permissive; only its art/audio is locked), (3) Luanti's `mobs_redo` attack-type taxonomy (MIT), (4) Mario-style enemy behaviours as readable Lua in mari0_ae (WTFPL code), and (5) Cataclysm-DDA's 1,747 food records, 5,589 recipes, 1,428 uncraft (salvage) records and 536 base-upgrade recipes. Nothing shipped is both CC0 and a good stylistic fit: keep art and sound procedural, and treat CC0 packs (section d) as optional.
Ranked, best reuse per effort:
1. **DwarfCorp `DwarfCorpContent/World/ResourceItems/*.json`** (156 items, 106 craftable, 9 station types, tag ingredients) -> JS recipe+food+potion table. Effort S-M.
2. **Flare `mods/empyrean_campaign/{enemies,powers,npcs,quests}`** -> copy the *schema*: enemy = stats + `power=<melee|ranged|on_join_combat>,<id>,<chance>` lines; NPC = `vendor`, `status_stock`, `[dialog] requires_status`. Covers healer/summoner/shielded/boss + town in one pattern. M.
3. **Luanti `mobs_redo` `api.txt` + `mobs_monster/*.lua`** (MIT) -> port 11 monster definitions and the `dogfight/shoot/dogshoot/explode` + `runaway/group_attack/fly` vocabulary. S.
4. **mari0_ae `enemies/*.lua` + `customenemies/*.json`** -> re-implement hammer-thrower, lakitu-flyer, boo-ambusher, bomb, chain-chomp charger, boom-boom mini-boss. M (original look only).
5. **CDDA `data/json/items/comestibles`, `recipes`, `uncraft`, `requirements`, `recipes/basecamps`** -> mine numbers and structure, rename everything. M.
6. **three-fps `src/FiniteStateMachine.js` + `entities/NPC/CharacterFSM.js`** (MIT) -> 40-line FSM and Idle/Patrol/Chase/Attack/Dead states. S.
7. **TownGeneratorOS (cloned, GPL-3.0)** -> study the ward/Voronoi/lot-cutting algorithm and re-implement for the hub layout. L.
8. **Flowerbed `selectionWheels/`, `seedbox/`, `UIPanel.js` + IWSDK `xr-input/gamepad`** (MIT) -> VR-usable recipe UI patterns (canvas panel + ray, radial wheel). M.

## (b) Tables
### Food (ingredients and consumables with buffs, spoilage-free)
| need | best source (paths) | licence | how to use | effort | risk |
|---|---|---|---|---|---|
| nutrition and effect numbers | cleverraven/cataclysm-dda `data/json/items/comestibles/*.json` (35 files; 1,747 COMESTIBLE records under data/json: 604 FOOD, 220 DRINK, 93 MED; fields calories, quench, fun, healthy, vitamins; 725 carry `spoils_in`, ignore) | CC BY-SA 3.0 | port numbers to a JS table, rescale to heal/buff size, own names and text | S | share-alike if shared; post-apoc flavour |
| fantasy foods and potions | cdda `data/mods/Magiclysm/items/comestibles.json`, `alchemy_items.json` (98 foods in mod) | CC BY-SA 3.0 | reference / port subset | S | same |
| minimal hunger values + 6 potions | blecki/dwarfcorp `World/ResourceItems/{Bread,Meal,Meat,Ale,Apple,Berry,Mushroom,PotionOfHealth,PotionOfSpeed,PotionOfStrength,...}.json` (14 foods with `FoodContent`, e.g. Meal 500, Bread 350, Meat 250) | modified MIT (data free; images/models/SFX/music proprietary) | port table | S | tiny set |
| crop -> ingredient -> dish graph | tenplus1/farming `item_food.lua` (80 foods, 70 with `item_eat`), `item_recipes.lua` (174 recipes), `crops/` (42 crops) | MIT code; textures CC0 + CC BY-SA 3.0/4.0 mix | port graph; ingredient groups (`group:food_flour`) as tags; skip textures | S-M | Lua; Luanti-specific nodes |
| item -> timed buff indirection | flareteam/flare-game `mods/empyrean_campaign/items/categories/potions.txt` (10 potions `power=`), `powers/effects.txt` (38 effects: speed, shield, resist_all, return_damage...) | CC-BY-SA 3.0 | adopt item -> power -> effect design; stacking rules are ours | S | none |
| icons | procedural `rpgIconBase` already in game; CC0 option is Kenney Food Kit (not pulled) | n/a | keep procedural | n/a | n/a |
| spoilage | ryankopf/colony `src/spoilage_system.rs` (29 lines), `needs.rs` (44) | MIT (README: MIT/Apache-2.0) | skip, spoilage-free by design | n/a | n/a |

### Mobs (>= 10 new types, boss patterns)
| need | best source (paths) | licence | how to use | effort | risk |
|---|---|---|---|---|---|
| data-driven attack lists, healer/summoner/shield/boss | flare-game `enemies/*.txt` (142), `powers/powers.txt` (+ `powers/base`, 425 `[power]` blocks); see `enemies/lvl10_minotaur_necromancer.txt` (summon + heal minions + force field, `chance_flee`), `il_boss_razu.txt` | CC-BY-SA 3.0 | adopt schema, author ~12 original archetypes | M | art is 2D iso, data only |
| behaviour vocabulary + ready tables (ranged, bomber, flyer, runaway, group attack) | tenplus1/mobs_redo `api.txt` (972 lines), `api.lua` (attack branches ~L2117-2350); mobs_monster 11 monster files (28 register calls) incl. `dungeon_master.lua` (dogshoot, fireball arrow, hp 42-75), `oerkki.lua`, `spider.lua` | MIT (mobs_redo textures CC0 + 3 CC BY-SA) | port tables; re-implement state logic | S | none |
| Mario-flavoured moves | alesan99/mari0_ae `enemies/{hammerbro 994L,lakito,boo,bomb,chainchomp,rockywrench,magikoopa,boomboom 550L,thwomp,pokey,bulletbill}.lua` (50 files), `customenemies/*.json` (28 data-defined: movement, jumps, `spawnsenemy`, delays) | WTFPL (code only) | re-implement behaviours; take no sprites/sounds | M | Nintendo-derived art; keep looks original |
| boss pattern reference | sm64js `src/game/behaviors/{king_bobomb,bobomb,boo,chain_chomp,chuckya,bully,thwomp}.inc.js` (105 files); n64decomp/sm64 `src/game/behaviors/` (226 files) | WTFPL / CC0 labels on Nintendo-derived code | read for phase timing only; write from scratch | M | highest IP risk, never paste |
| stat + special-attack catalogues | cdda `data/json/monsters/*.json` (1,221 MONSTER, 68 files; specials: grab 85, bite 65, leap 57, gun 49, spell 49), `data/mods/Magiclysm/monsters/{goblin,orcs,ogre,golems,dragon,lizardfolk}.json` (484 in mod), `src/monattack.cpp` (82 special-attack fns: resurrect, nurse_assist, kamikaze, grenadier, shriek, leap) | CC BY-SA 3.0 | reference for balance + ideas | S | zombie theme |
| FSM and steering | mohsenheydari/three-fps `src/FiniteStateMachine.js` (41L), `entities/NPC/CharacterFSM.js` (220L), `entities/Level/Navmesh.js` (three-pathfinding) | MIT | adapt directly (plain JS) | S | its Mixamo anims not reusable |
| raid/event mobs | dwarfcorp `World/Classes/*.json` (33; weapon Mode: Melee 24, Ranged 7, Dogfight 2, Area 1; projectiles Fireball/Web/Arrow/Mud/Snowball), `World/Events/*.json` (7) | modified MIT | port as spawn-event table | S | none |
Note: game already has 8 elite affixes (shielded, summoner, volatile, vampiric, frozen, thorned...). Promote them into base types instead of duplicating.

### Crafting (materials, stations, upgrade/reforge, gamepad + VR recipe UI)
| need | best source (paths) | licence | how to use | effort | risk |
|---|---|---|---|---|---|
| recipe schema: tag ingredients, station, time, tool kept | dwarfcorp `ResourceItems/*.json` (`Craft_Ingredients` by Tag, `Craft_Location`: Craft Table 63, Anvil 20, Apothecary 7, Forge 6, Cutting Board 2, `Craft_BaseCraftTime`, tool `Durability`); gotmayonase/pz-modding-guide `recipe-scripting.md` (139L, `mode:keep` tools) | modified MIT; PZ guide none found (reference only) | port schema to JS tables | S | none |
| any-of component resolution, shared bundles | cdda `data/json/recipes/**` (5,553 recipes; CC_FOOD 740, CC_ARMOR 465, CC_WEAPON 280), `data/json/requirements/` (475 `requirement` records), `src/requirements.cpp` (1,871L) | CC BY-SA 3.0 | re-implement resolver: `[[a,b],[c]]` = (a or b) and c | M | scope creep: keep to 2 levels |
| salvage / disassembly | cdda `data/json/uncraft/` (1,428 `uncraft` records, most in that dir) | CC BY-SA 3.0 | table of item -> materials; game already has dust salvage | S | none |
| upgrade / reforge | PathOfBuilding `src/Data/Essence.lua` (104 essences = guaranteed affix), `ModExplicit.lua` (4,221 mods) | MIT code, GGG-owned data | concept only: essence = forced affix, upgrade = ilvl tier bump (existing `RPG_TIER_ILVL`, `rpgRerollAffix`) | S | do not copy names/values |
| gathering and material nodes | flare-game `items/categories/crafting.txt` (5 materials), `loot/*.txt` (47 level-scaled tables); farming `crops/` (42) | CC-BY-SA 3.0; MIT | node-drop tables via existing `rpgDrops` | S | none |
| gamepad + VR recipe UI | meta-quest/projectflowerbed `src/js/systems/selectionWheels/` (524L), `seedbox/` (438L paged palette), `lib/objects/UIPanel.js` (629L, three-mesh-ui); facebook/immersive-web-sdk `packages/xr-input/src/gamepad/` (482L, three >=0.160), `packages/core/src/ui/` (1,402L, @pmndrs/uikit) | MIT | adapt patterns: canvas-texture panel + ray pick + radial wheel; DOM overlays are invisible in immersive mode | M | Flowerbed is a three r144 fork + ECSY; IWSDK is TS + build step |
| crafting/UI sounds | flowerbed `content/audio/sounds/` (62 wav: seed planting, watering, UI open/close, footsteps) | CC BY 4.0 (attribution) | optional static files | S | attribution line |

### Town hub (vendor, cook, smith, stash, quest board -> Shatter Rifts, growth, dialogue)
| need | best source (paths) | licence | how to use | effort | risk |
|---|---|---|---|---|---|
| procedural village layout | watabou/towngeneratoros `Source/com/watabou/towngenerator/{building/Model,Patch,Cutter,CurtainWall,Topology}.hx`, `wards/*.hx` (13 ward types), `geom/Voronoi.hx` | GPL-3.0 | re-implement algorithm; map wards to vendor/cook/smith/stash plots | L | do not paste code |
| NPC roles, shop stock unlocked by flags, dialogue gates | flare-game `npcs/*.txt` (31; `vendor=true`, `constant_stock`, `status_stock=<flag>,<ids>`, `[dialog]` `requires_status`), `quests/*.txt` (13; `requires_item`, `complete_status`, e.g. `0011_alchemy.txt`) | CC-BY-SA 3.0 | adopt flag model as JS `town.flags`; write own lines | M | none |
| quest board -> rifts | cdda `data/json/npcs/missiondef.json`, `faction_missions.json` (355 mission_definition); dwarfcorp `World/Events/*.json` (Likelihood, Difficulty, Cooldown, AllowedTime) | CC BY-SA 3.0; modified MIT | port mission schema; reward/seed fields link to `rpgRiftSpec` | S-M | none |
| town growth from resources | cdda `data/json/recipes/basecamps/` (78 files: 536 recipes + 62 recipe_groups = tiered upgrade chain), `src/basecamp.cpp` | CC BY-SA 3.0 | port as `TOWN_UPGRADES` tier table (cost, unlocks) | S-M | none |
| dialogue DSL | dwarfcorp `YarnSpinner/` (C#) + `DwarfCorpContent/employee.conv`; flare `[dialog]` | MIT | mimic a tiny Yarn-like JSON tree | S | none |
| vendor pricing / restock | cdda `src/npctrade.cpp` (382L), `data/json/npcs/shop_consumption_rates.json`; own `RPG_TUNING.drop` can fill stock (`source:'vendor'`) | CC BY-SA 3.0 | re-implement simple price/markup | S | none |
| role archetypes only | diasurgical/devilutionx `assets/txtdata/towners/towners.tsv`, `quest_dialog.tsv`, `text/textdat.tsv` (338 rows) | Sustainable Use, Blizzard content | structure only (smith/healer/tavern/witch + gossip rotation) | S | no names or text |
| village props, footsteps | flowerbed `content/models/props` (128 gltf total), footsteps dirt/grass/stone/wood | CC BY 4.0 | optional static files | S | style mismatch, KTX2 textures |

## (c) Licence caveats (plain)
- **CC BY-SA 3.0** (all of Cataclysm-DDA incl. its code and Magiclysm; Flare Empyrean art + data): free for private use. If the game is ever shared, even for free, anything adapted from them needs credit and must be offered under CC BY-SA, which collides with a closed single-file game. Mitigation: copy numbers and structure, write our own names/prose, keep a list of what was derived.
- **GPL-3.0** (flare-engine, TownGeneratorOS, openrw, rsg-core, forbidden-flesh, another-try, colonize, pz-zdoc): never paste into a game we might share; read, then re-implement. Flare's AI_POLICY.md governs contributions upstream only.
- **Sustainable Use** (devilution, devilutionX): non-commercial, free distribution only; Blizzard-derived data (monsters, towners, text) is **reference only**. diabloweb has no licence file and is built from it.
- **Nintendo-derived**: sm64js (WTFPL label), n64decomp/sm64 (CC0 label), mari0_ae sprites/sounds. A label cannot grant Nintendo's rights; sm64js ships extracted models/animations/audio (123 actors). Behaviour *ideas* only; no code or assets pasted; keep creatures original.
- **PathOfBuilding**: MIT code, but `src/Data/*` is Grinding Gear Games data (header says "Item data (c) Grinding Gear Games"). Reference only.
- **DwarfCorp**: code and JSON data are MIT; images, 3D models, sound effects, music are proprietary by its own LICENSE.txt.
- **No licence file** (all rights reserved by default, reference only): diabloweb, StatsAPI, both PZ guides, gta-reversed. barking-irons README claims MIT but its art is not distributable; souls-like-controller README says "do whatever" with no file and needs assets it cannot ship. pz-api-docs has a custom permissive note (docs only). UEVR is "All rights reserved". FiveM is Rockstar CPL.
- **Assets**: Flowerbed content is CC BY 4.0 (attribution required; Roboto Apache-2.0). openfw-game and RiftBreakers models come from Sketchfab (CC-BY-4.0 or Standard licence; Attack-on-Titan IP): skip. colony's "RPG Graphics" (110 icons) and "RPG Sound Pack" have no provenance; its DCSS tiles are CC0 per README only.
- Corrections to SOURCES.md: UEVR is All-rights-reserved (not an open licence); sm64 LICENSE.md is CC0 text on Nintendo-derived code; pz-zdoc is GPL-3.0; colony's LICENSE file is MIT text only (README adds Apache-2.0); flare-engine has no items/enemies/loot content.

## (d) Cloned for this task (5 repos, all public, no LFS)
1. `flareteam/flare-game` -> /home/user/flareteam/flare-game, **blobless sparse, 4.3 MB** (enemies, items, powers, npcs, loot, quests, books, engine, README/LICENSE/CREDITS; no art or sound). A plain shallow clone was 2.2 GB (over the 300 MB cap), so I deleted that clone and re-cloned sparse; same record counts verified (556 `[item]`, 425 `[power]`, 142 enemies, 31 npcs, 47 loot, 13 quests).
2. `tenplus1/mobs_redo` (Codeberg) -> /home/user/tenplus1/mobs_redo, 0.9 MB, MIT.
3. `tenplus1/mobs_monster` (Codeberg) -> /home/user/tenplus1/mobs_monster, 2.3 MB, MIT.
4. `tenplus1/farming` (Codeberg) -> /home/user/tenplus1/farming, 3.5 MB, MIT code + mixed media licences.
5. `watabou/TownGeneratorOS` -> /home/user/watabou/towngeneratoros, 0.6 MB, GPL-3.0.
Not cloned, up to 8 proposals (page facts verified 2026-10-10 unless "est."; the GitHub API was blocked, so sizes are estimates):
- Kenney Food Kit, https://kenney.nl/assets/food-kit, CC0, 200 files (zip), est. 10-30 MB: food models. Kenney Fantasy Town Kit 2.0, https://kenney.nl/assets/fantasy-town-kit, CC0, 160 files, est. under 30 MB: village props.
- Quaternius Medieval Village MegaKit, https://quaternius.com/packs/medievalvillagemegakit.html, CC0, 300+ modular pieces (glTF/FBX/OBJ), est. 50-150 MB: hub buildings (could be voxelised).
- kchapelier/wavefunctioncollapse, https://github.com/kchapelier/wavefunctioncollapse, MIT, JS, est. under 1 MB: tile-based house/village generation that drops into a single file.
- tenplus1/mobs_animal, https://codeberg.org/tenplus1/mobs_animal, licence.txt present (contents unread; sibling mods are MIT), 1.3 MiB: raw meat/egg/milk drops for a cook NPC.
- Veloren, https://gitlab.com/veloren/veloren, code GPL-3.0+, asset licence unverified, large (18,558 commits): sparse-clone `assets/common` for loot/recipe/trade data. Reference only.
- Brogue CE, https://github.com/tmewett/BrogueCE, AGPL-3.0, est. under 20 MB: compact monster catalogue with ability flags. Reference only.
- Shattered Pixel Dungeon, https://github.com/00-Evan/shattered-pixel-dungeon, GPL-3.0, est. 100-250 MB: mobs, boss phases, alchemy recipes (from memory). Reference only.

## (e) Unknowns
- flare-game art/sound not checked out; its CREDITS.txt mixes CC-BY-SA, CC-BY and CC0 per artist. Verify per file before using any audio.
- Whether CC BY-SA obliges credit/sharing for purely numeric facts is a legal question I did not settle; the plan above avoids it by not copying text.
- mobs_redo sound licences (only the first 30 lines of `license.txt` read). Quaternius/Kenney/Veloren sizes and Veloren asset licence unverified.
- No repo provides an instanced, many-entity mob renderer: 10+ enemy types at VR's 72 Hz budget is unproven. Flowerbed's `three-instanced-uniforms-mesh` + LOD configs are the nearest hint, on a r144 fork.
- mari0/sm64 behaviours were read at file level (sizes, names, schema), not traced line by line; confirm each move before porting.
- Per-repo roll-up below was judged from README, licence file and layout; repos not related to the four features were not read deeply.

## Appendix: all 42 repos (language | licence file | relevance)
| repo | lang | licence (real file) | relevance |
|---|---|---|---|
| cleverraven/cataclysm-dda | JSON 6,692 + C++ | CC BY-SA 3.0 (LICENSE.txt; fonts OFL/Apache) | HIGH all four |
| blecki/dwarfcorp | C# + JSON | modified MIT, art/audio excluded (LICENSE.txt) | HIGH crafting, food, mobs, events |
| flareteam/flare-engine | C++ | GPL-3.0 (COPYING); default mod GPL-3 + CC-BY-SA 3.0 | MED: source for AI/loot/vendor (`EntityBehavior.cpp`, `LootManager.cpp`, `MenuVendor.cpp`), no content |
| alesan99/mari0_ae | Lua | WTFPL (LICENSE.txt) | HIGH mobs (code only) |
| sm64js/sm64js | JS 1,509 | WTFPL (LICENSE), Nintendo-derived | MED mobs, reference only |
| n64decomp/sm64 | C | CC0 text (LICENSE.md), Nintendo-derived | LOW reference only |
| mohsenheydari/three-fps | JS | MIT (LICENSE) | MED mobs FSM |
| meta-quest/projectflowerbed | JS | MIT; content CC BY 4.0 | MED VR UI, audio |
| facebook/immersive-web-sdk | TS | MIT (LICENSE) | MED VR input/UI |
| meta-quest/webxr-first-steps | JS | MIT | LOW |
| diasurgical/devilution, devilutionx | C++ | Sustainable Use (LICENSE.md) | MED reference: tables, towners, stores |
| d07riv/diabloweb | JS + WASM | none found | LOW |
| pathofbuildingcommunity/pathofbuilding | Lua | MIT code, GGG data | MED crafting reference |
| ryankopf/colony | Rust | MIT text (LICENSE); README adds Apache-2.0 | LOW (needs, tasks, path) |
| noidexe/top-down-action-rpg-template | GDScript | MIT (LICENSE) | LOW town skeleton (`Dialogs.gd`, `Quest.gd`, `Inventory.gd`) |
| konstantinkolo/riftbreakers | GDScript | MIT (LICENSE); assets third-party | LOW |
| prashanna135/souls-like-controller | GDScript | none file (README: free) | LOW (inventory/consumable scripts) |
| ciken-taste/forbidden-flesh | GDScript | GPL-3.0 | LOW |
| ivessjohn/barking-irons | GDScript | none file (README: MIT) | NONE |
| openfw-game/{apple-seed,crawling-agony,defy,openliberty} | GDScript | MIT (LICENSE/LICENCE) | LOW (crawling-agony `gdd.md` design notes only) |
| reterics/another-try | TS | GPL-3.0 | LOW |
| indiv0/colonize | Rust | GPL-3.0 | NONE |
| rexshack-redm/rsg-core | Lua | GPL-3.0 | LOW (512-item registry, no stats) |
| gotmayonase/pz-modding-guide, fwolfe/zomboid-modding-guide, demiurgequantified/statsapi | MD, Lua | none found | LOW reference (recipe/item script syntax) |
| cocolabs/pz-zdoc (GPL-3.0), pz-wiki-modding/pz-api-docs (custom permissive) | Java, Python | as listed | NONE |
| pardeike/harmony (MIT), praydog/uevr (All rights reserved), citizenfx/fivem (Rockstar CPL), rwengine/openrw (GPL-3.0), gta-reversed/gta-reversed (none found) | C#, C++ | as listed | NONE |
| junior37534/questbridge, sm1jjj/pipelinklauncher, mrborghini/libertycraft, cyteon/grandtheftminecraft, codebyalexff/garrys-redemption | Java/Python/C++ | MIT each | NONE |
