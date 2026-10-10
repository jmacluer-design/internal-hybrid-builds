# Outbreak sim core: design notes

Scope of this pass: the game-agnostic simulation of a zombie-survival + colony-manager hybrid ("the brain"), pure Lua, no game calls,
testable here under LuaJIT 2.1 and Lua 5.4. The FiveM adapter (peds, cameras, objects) and the NUI pages come later and build on the
contract in `API.md`. Everything below is **unverified against any game**: it was built and tested against the sim's own mock harness.

## 0. Quick start

```
tests/run.sh                 # whole suite under luajit AND lua5.4, cross-runtime hash compare, bench (about 3 minutes)
tests/run.sh fast            # skip soak + bench (about 1.5 minutes)
luajit tests/run.lua jobs    # one test file under one runtime
luajit bin/sim-run.lua --days 30 --seed 7 --profile escalating [--colonists 6] [--step 1] [--no-policy] [--hash]
luajit bin/balance.lua --seeds 200 --step 5            # survival-to-day-30 and events/day per profile
luajit tests/bench.lua                                  # ms per tick
```

## 1. Layout

```
sim/    modules (pure Lua; `require("sim.world")` is the entry point)
data/   every balance number and content table (tuning, items, blueprints, loot, traits, thoughts, events, factions, districts, recipes, names)
tests/  tinytest harness, 22 test files, run.lua (one runtime), run.sh (both runtimes + cross-runtime hash + bench), bench.lua, hash_check.lua
bin/    sim-run.lua (headless colony + per-day report), balance.lua (many seeds per profile)
API.md  the adapter contract (checked against the code by tests/contract_test.lua)
```

| module | job |
|---|---|
| `util` | portable helpers: stable sort, sorted-key iteration, canonical number format, arithmetic string hash, id counters |
| `rng` | Park-Miller / Lehmer (a=48271, m=2^31-1), exact in doubles and int64; `fork(label)` gives independent streams |
| `clock` | minutes since day 1; day/night, daylight ramp, seasons |
| `items` | item defs, weight/stack/slot-limited containers, atomic transfer, invariant checker |
| `loot` | weighted loot tables, danger tilt for rare entries, luck |
| `needs` | hunger, thirst, fatigue, bleeding, pain, wounds, infection state machine, treatment, amputation-lite |
| `mood` | thoughts with fade/stack, need-derived modifiers, mental breaks (refuse / binge / wander) |
| `skills`, `traits` | six skills with xp curve; 17 original traits |
| `colonist` | stats, carry limit, priorities 0..4, 24 h schedule, combat power |
| `stockpile` | zones with category filters and priorities |
| `blueprints` | 16 buildings: materials, work, prerequisites, defense, hp, repair; defense/enclosure scores |
| `grid` | power (mains + generators, brownout shedding) and water (tank, collectors, outages), weather |
| `jobs` | job board, priority assignment, reservations, multi-step execution, interruption, aging |
| `expedition` | abstract scavenging trips by vehicle or on foot |
| `horde` | abstract hordes on a coarse grid; noise; materialize / dematerialize with hysteresis and a cap |
| `siege`, `combat_abstract` | off-screen fights resolved from the rng; consequences applied to the world |
| `factions` | four gangs + a survivor camp: goodwill, raids, caravans, trade / gift / truce |
| `director` | the storyteller: threat budget, three pacing profiles, event table |
| `world` | orchestrator: `tick`, `handle`, ledger, entity index, deaths, refugees, reports |
| `handlers` | IN events and player orders |
| `save` | canonical serializer, versioned header + checksum, migrations |
| `ai_policy`, `runner` | the default headless "player" used by `sim-run`, `balance`, the soak and the hash check |
| `bootstrap` | `require` over a host-supplied file reader, for hosts without `package.path` (FiveM); tested in a fresh process |

## 2. State, determinism, conservation

* **One plain-data state** `w.s` (numbers, strings, booleans, tables; no functions, no metatables that matter). Everything derived lives in `w.rt`
  (id indexes, job reservations, event buffer) and is rebuilt by `World.restore`. The job board, the director budget, noise log and RNG states are all in `w.s`,
  so `load(save(w))` followed by ticking evolves **exactly** like the unsaved world (tested).
* **Entities are arrays plus an id index**, never iterated with `pairs` where order could matter. The portability lint (`tests/util_test.lua`) fails the build on:
  `goto`, bit operators, `//`, `^`, `math.pow/exp/log/sin/cos/...`, `os.time/clock`, `math.random`, `string.pack`, `setfenv`, `utf8`, unannotated `pairs()`, `table.sort`
  outside the helpers, bare `unpack`. Sorting uses a stable merge sort (`U.sort`) because `table.sort` is not stable and differs between runtimes when the comparator has ties.
* **Numbers into text only through `string.format("%d" / "%.1f")` or `U.fmt_num`** (5.4 prints `3.0`, LuaJIT prints `3`); states are hashed from the canonical serialization (`%.17g`).
* **Hashing** is a two-lane arithmetic hash (products stay below 2^47, exact in doubles). `w:hash()` is the identity of a state; the cross-runtime test compares it for four 30-day runs.
* **RNG streams**: `master` is forked by label into `needs`, `mood`, `injury`, `medical`, `horde`, `siege`, `exped`, `loot`, `fac`, `director`, `grid`, `refugee`, `setup`. A new feature
  using its own label cannot perturb an existing stream.
* **Item conservation**: items enter only through `world:create(container, id, n, reason)` and leave through `world:destroy(...)`; the ledger counts both by item and by reason.
  `world:audit()` checks that for every item the sum over *every* container (colonists, zones, piles, construction sites, the player, adapter containers, expedition loot, caravans, raiders)
  equals `created - destroyed`, and re-verifies every container's cached weight / stack counts. Moves are atomic (`items.transfer` moves exactly what the target accepts).
  The fuzz and soak tests call the audit thousands of times.
* **Time**: the sim advances in whole minutes (`tick(n)`; optional `max_dt` substeps for fast balance runs). Jobs are timed by the sim (walking time = distance / walk speed + work
  time / worker speed); the adapter animates and never reports completion.

## 3. Subsystems

### Needs and infection
Hunger / thirst / fatigue / pain are 0..100 where higher is worse. Wounds carry a bleed rate (hp/min) that clots on its own for small cuts; deep wounds need a bandage (a kit closes everything).
Infection: `none -> incubating (silent, 8-18 h) -> symptomatic (fever, slow, hp drain, 10-18 h) -> terminal (2-5 h) -> death (reanimates)`. Bites infect with p = 0.30 (scratches 0.04).
Treatments: antibiotics (cure chance 90% incubating / 55% symptomatic / 12% terminal, +2.5% per medicine level; a failed course buys 30% more time), rest (progress x0.75),
amputation-lite (limb bites only, incubating or symptomatic, 80% + 2% per level, costs hp and 10% speed forever). Everything is clamped for any `dt`; the tests push dt from 0 to 5000.
The incubating stage is **hidden** from `colonist_state`; doctors give antibiotics to anyone with a fresh bite wound, so supplies are spent speculatively (a design choice).

### Mood
Base 50 + trait offsets + thoughts (value, duration, `decay_start`, stack limit) + need penalties (hunger, thirst, tiredness, pain, sickness, maiming). Below 30 / 20 / 10 a colonist
may break (4 / 10 / 25 % per hour): `refuse` (no work), `binge` (eats up to 3 stock items), `wander` (leaves for a while; at extreme level 8% never returns). 8 h cooldown, relief thought afterwards.

### Jobs
* Work types: `doctor, guard, build, cook, craft, haul, scavenge` (priority 0 = never .. 1 = highest; ties broken by that fixed order, then urgency, then distance).
* Needs jobs (`eat`, `drink`, `sleep`, `rest`, plus break jobs) are generated per colonist, not from the board, and have **classes**: 1 work, 2 need, 3 urgent (starving, collapse, heavy bleeding, mental breaks), 4 forced
  (orders, draft). A strictly higher class interrupts; equal classes never swap; a colonist re-evaluates when idle, when flagged dirty, or every ~10 minutes.
* The **board** is rebuilt every 5 minutes from world state (haul piles, deliveries, builds, repairs, refuel, cook / craft stations, doctor jobs, guard posts, expedition volunteering) and stored in state with
  a `since` time per job.
* **Aging bound**: a job that has waited `aging_minutes` (300) is treated one priority step higher per period; once it reaches the top it beats fresh jobs of the same priority. A low-priority job is therefore
  served within about 3 periods even under a constant stream of priority-1 work (tested). Priority 0 is never served.
* **Reservations**: every job has keys with a capacity (1 for almost everything); the table is derived from colonists' jobs so it cannot drift (`check_reservations` is run in the fuzz / soak).
* Jobs are lists of steps `{pos, dur, act}` executed by small action handlers; interruption aborts cleanly (items carried stay in the colonist's inventory and are stocked by the next `unload`).
* Stale board entries are re-validated at planning time (a refuelled generator, an already-treated patient...).

### Hordes
`s.hordes` groups with continuous position, composition, heading and speed on a coarse cell grid (cell = 200 units; cells are for indexing and noise queries). They wander (small turn chance, 6% of walking speed),
and head for noises: a noise of loudness L attracts hordes within `L x 3` units, with a score decaying by distance; the best-scored target wins. A horde that reaches the base ring assaults it
(`siege.resolve` every 10 minutes) if no observer has it materialized. **Materialization**: within `R_materialize` (220) of an observer it emits `spawn_horde`, within the cap
(`max_materialized` 40 across hordes and raiders, `per_horde_max` 28) and only despawns beyond `R_dematerialize` (380) after `min_dwell` (4 min). Real peds that die are reported back and
shrink the abstract group; killed peds free cap room and trigger top-ups. Hordes merge within 90 units, are capped at 24 groups, and old ambient ones thin out.

### Abstract combat
A round: defenders kill `k_kill x defender power x readiness x (1 + shooter bonus behind walls) x U(0.6,1.4)` attacker power; attackers deal `k_damage x remaining power x wall multiplier` in quantized ~9 hp hits
(bites vs scratches; raiders shoot). Walls wear as they absorb. Readiness: guards / drafted 1.0, awake workers 0.55 (x1.3 on alert), sleepers 0.3. Ranged defenders spend ammo and fight at 40% when dry.
The result is applied by `siege`: wounds, ammo destroyed, structures damaged, noise (gunfire and screamers attract more hordes), kill credit (xp).

### Expeditions
Open sign-up through the `scavenge` work type (or explicit crew); a van costs fuel cans (round trip / 150 min), foot trips cost nothing but reach only nearby districts, take 2.5x longer and are riskier.
Up to three ambush rolls (out, searching, back) with chance by district danger (10% .. 52%), x1.5 at night, reduced by crew skill; an ambush is resolved with `combat_abstract` against the crew.
Crew can be hurt, infected, separated (lost) or wiped out (loot gone, vehicle lost with 60%). Loot is rolled from the district's table (danger tilts rare entries; scavenging and luck add rolls),
capped by the trunk, and returns as a ground pile at the garage with a `loot_spawn`.

### Factions, raids, caravans
Four gangs (Rustjaw Reavers, Hollow Choir, Tallow Syndicate, Cinder Union) and a survivor camp (Lantern Camp). Goodwill -100..100 drifts back to its starting value; raid weight = aggression x f(goodwill),
zero during a truce. Raiders approach at vehicle speed, assault (abstract) or materialize near the player, rob preferred categories when the defense collapses (stolen goods leave through the ledger).
Caravans stay 6 h with a stock rolled from the faction's table; trade is barter by item value with a markup, a premium for wanted categories and a goodwill price factor; deals are atomic.
Gifts raise goodwill (capped); a truce costs value proportional to hostility.

### Director
`threat points per day = mult(profile, day) x (8 + 3.5 x colonists + 1.2 x sqrt(wealth) + 0.9 x (day-1))` accrue into a **budget** (cap 2.5 days of income). Threat and hazard events (horde wave, gang raid,
infection outbreak, helicopter flyover, power outage, water outage, storm) fire from a **threat channel** with a randomized gap, only if the budget covers their cost, and spend it (so threat can never outrun what
the colony earned). Boons (caravan, supply drop, refugee) run on their own timer and are free. Day 1 is a grace day. Cooldowns and `min_day` are per event.

| profile | multiplier day 1 -> 30 | threat gap (days) | spend of budget | surge | feel |
|---|---|---|---|---|---|
| calm | 0.50 -> 1.05 | 1.3-2.8 -> 1.2-2.6 | 45-80% | 0 | long quiet stretches, boons weighted up |
| escalating | 0.55 -> 1.15 | 1.8-3.2 -> 0.35-0.85 | 55-85% | 10% | gentle start, steady ramp |
| chaos | 0.80 -> 1.05 | 0.25-0.8 -> 0.15-0.55 | 60-95% | 30% | short gaps, spikes, little rest |

(Isolated, with an immortal colony: calm leaves about 23 of 30 days free of threats, chaos about 2; escalating fires 2.3x more threat events in days 16-30 than in 1-15; `tests/director_test.lua` asserts all of this.)

### Save format
`OUTBREAK-SAVE <version> <payload length> <payload hash>\n` + canonical JSON-like text (sorted keys, `%.17g` numbers, `\xHH` escapes). Load verifies header, length and checksum, rejects newer versions,
runs `migrations[n]` (n -> n+1) in order (a real v1 -> v2 stub is included and tested), then rebuilds caches. Maps must have string keys and arrays must be dense; the serializer errors loudly otherwise.

## 4. Design choices the owner may want to change

1. **Sim time is authoritative**; colonists are not tied to ped positions. A slow ped is simply snapped. (Alternative: a `task_done` IN event.)
2. **Only the player is an observer** for materialization (`observe_colonists = false`). Colonists far from the player are simulated abstractly even when "in view" of nothing.
3. **Incubating infection is hidden**; doctors medicate fresh bites speculatively; amputation needs the per-colonist permission and a surgical kit and is offered only when antibiotics are gone.
4. **No food production** (no farming): food comes from expeditions, caravans, supply drops, refugees. This keeps the loop simple but makes scavenging mandatory (about one trip a day for 5 colonists).
5. **No currency**: barter only, by abstract item value (matches the plan's "no money mechanics").
6. **Death is permanent and absolute**; infected dead reanimate as a one-zombie horde after 3-12 minutes.
7. **One base** at the origin, one garage, one vehicle at the start; the district list is abstract (11 districts with original names).
8. **Combat is abstract and tuned for the default AI policy**; real in-game fights bypass it entirely, so difficulty in the actual game depends on the adapter's zombie AI, not on these numbers.
9. Colonists carry up to 14 stacks / ~16-35 kg; the main stockpile starts at 200 kg and grows with crates.
10. Two `data/` knobs the adapter will probably touch first: `horde.max_materialized` and the `R_materialize` / `R_dematerialize` pair.

## 5. Ideas taken from Cataclysm-DDA (read for ideas only; no code or data text copied; CC BY-SA 3.0 stays untouched)

* `src/horde_map.cpp`: hordes as abstract groups on a coarse map, tiered by activity, with individuals only materializing near the player -> our `horde` module (coarse grid, abstract groups, materialize near observers, cap).
  We use continuous positions, a hysteresis band and a shared cap instead of its tiers.
* `src/character_morale.cpp`: morale as a list of entries with bonus, duration and `decay_start`, plus capped stacking and persistent modifiers recomputed periodically -> our `mood` thoughts.
* `src/mission_companion.cpp`: companions sent on timed abstract missions whose outcome compares the crew's combat skill with the monsters met, with a randomization band (0.6-1.4) -> our `expedition`
  ambush resolution and the `combat_abstract` variance band.
* `src/basecamp.cpp` / `src/faction_camp.cpp`: a camp as a set of inventories / zones plus assignable work -> our stockpile zones and job board (re-designed around colony priorities, not copied).
No item, monster, mission or text data from the game is used. All names (gangs, districts, items, traits) are original.

## 6. Balance method and results

`bin/balance.lua` runs N seeds per profile with the default policy and prints survival to the end of day 30 (at least one colonist alive), average survivors, median director events per day,
threat days and the cause of death. Targets: calm 85-95%, escalating 35-60%, chaos 20-45%. The numbers are tuned against the **default AI policy** (`sim/ai_policy.lua`), which plays a competent but not clever
colony: it builds walls / towers / generator in a fixed order, drafts when a threat is within 420 units, scavenges when stocks run low and trades surplus. A better player will do better; a worse one, worse.
Knobs, most influential first: `director.profiles.*.mult1` and `.mult0`, `threat_gap*`, `combat.k_kill / k_damage`, `needs.infection.*`, `expedition.risk`, loot tables, starting stock.
See the final report / `bin/balance.lua` output for the latest measured numbers; the balance run uses `--step 5` (5-minute internal steps) for speed and was cross-checked at step 1 on a smaller sample.

## 7. Tests

`tests/run.sh` runs everything under both runtimes. Files: `rng`, `util` (+ portability lint), `loader` (bootstrap in a fresh process), `items`, `needs` (needs / infection / mood / skills / traits / colonist), `build` (blueprints, power, water),
`jobs`, `horde` (+ combat), `expedition`, `faction`, `director`, `world` (+ IN events and orders), `save`, `fuzz` (4000+ random operations with conservation checks after each), `contract` (API.md vs code),
`hash` (determinism), `soak` (30 days x 20 seeds), `bench`. Many assertions sit inside loops (each iteration counts), so the assertion total is large; the number of tests is the more honest size measure.

## 8. Known limitations

* No farming, no research tree, no power-based lighting effects beyond the `lights_out` thought, no weather effect on zombies, no sound occlusion, no multi-base.
* Combat is a single-number model: no cover, no friendly-fire, no melee vs ranged geometry.
* Vehicles are not physical objects here; expeditions are abstract (the adapter may show a convoy leaving).
* The default policy is simple; it does not use gifts, truces, medical beds or radio masts deliberately.
* Float determinism was verified on x86-64 only. LuaJIT's arm64 backend may fuse multiply-adds; if the adapter ever needs cross-architecture identical saves, add rounding at the boundaries.
