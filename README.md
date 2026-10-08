# internal hybrid builds — RDW labz

PS-style game shelf: pick a build, play it, save data persists, back out and switch games.

## Layout
- `source/` — raw clone repos we pulled (universal-modder, rea, SkyCraft, iw4L, 2010-rust-rewrite-mashup, SkateGM, er-mario, ArkWeb, skate3clone, ghidra-mcp, awesome-game-mashups, ai-game-modding-guides)
- `games/` — deliverable hybrids (neondrift, blockshot) — each is one self-contained HTML file
- `index.html` — the shelf/dashboard (loads save state from the relay, tiles launch games)
- `pad.html` — phone-as-controller: two thumbsticks + buttons, posts key events to the relay
- `serve.py` — static server + save relay (`/api/save`) + input relay (`/api/input`)
- `saves.json` — per-game save data (gitignored)

## How it works
- Games embed a **shelf bridge**: when served over http(s) from this server they
  poll `/api/input` (pad events → game's keys Set / fire / place / menu) and push
  death stats via `POST /api/save?game=<id>`. Opened standalone (data: URL) the bridge no-ops.
- `pad.html` on a phone: left/right thumbstick drags → movement keys, buttons →
  jump/fire/place/mode-toggle/pound, ⏎ → back to shelf. One shared session id (`sid=main`).

## Run
`python3 serve.py` → http://host:8732. TV = browser on the dashboard; phones open `/pad`.

## Roadmap (when server room is up)
1. Host on the server room box; expose at **game.cluerholdings.com** (nginx/`caddy` static +
   the same tiny API; keep saves.json on the box).
2. HTTPS → pad.html works on phones over the network; add LAN-only auth or a token if public.
3. Pad upgrades: Gamepad API (WebRTC input bridge or a real pad PWA with button mapping),
   per-player `sid` for 2P, rumble/haptics later.
4. Add hybrids to the shelf one at a time (killcraft-runner, ArkWeb swing-port, portal biomes).

## Conventions
- One file per game; spine = lane/spawn waves + pooled objects + state machine
  (see skill `threejs-game-clone-morph` for the verified build/verify workflow).
