# Handoff: set up the 5090 box as the game / VR host

You are a Claude Code session running on the owner's RTX 5090 PC. A cloud session built everything in this repo and cannot reach this
machine. You can. Read this file, then `hostkit/README.md`, `hostkit/AGENTS.md` and `hybrids/outbreak/PLAN.md`. Branch: `claude/zealous-bell-jownt4`
(the cloud session keeps pushing there; do your work on your own branch `local/5090` and push it, the cloud session merges).
Private, non-commercial hobby use. The owner owns the games and runs everything on their own machines.

## Why this box
The 5090 is the strongest GPU the owner has (a 4090 box is Linux, `michael2026` is a Windows PC with unknown GPU, plus two 5070s). Goal: ONE host that
(1) runs real PC games and mods, (2) streams them to a browser / tablet / TV / Quest over the owner's Tailscale network, (3) later runs the "Outbreak" GTA V hybrid.
The browser games on `game.cluerholdings.com` are already live and need nothing from this box.

## State of the world (what exists, what does not)
| Item | State |
|---|---|
| Browser games shelf (private, password gate) | Live. Nothing to do here. |
| `hostkit/windows/01-diagnose.ps1`, `02-install-streaming.ps1`, `03-tailscale-serve.ps1` | Written, **never run on a real machine** (the cloud sandbox has no PowerShell). Expect bugs: read each script first. |
| `hostkit/linux/01-diagnose.sh` | Run once in a sandbox only (no GPU). |
| Streaming stack (Tailscale + Sunshine + Moonlight-Web) | Researched, **nothing installed or tested**. |
| Outbreak (GTA V / FiveM colony x zombie survival) | Plan only (`hybrids/outbreak/PLAN.md`). The pure-Lua sim core is being built in the cloud (`hybrids/outbreak/sim`); the FiveM adapter does not exist yet. |
| WebXR VR for the browser games, loot/leveling pass | Being built in the cloud. Not your concern; do not touch `games/` or `hybrids/outbreak/sim|data|tests`. |

## Rules
1. Diagnose first, change nothing until the owner has seen the output. Ask before: driver installs/updates, Windows settings, firewall changes, deleting anything, disk partitioning.
2. Never commit or upload game files, ROMs, ISOs, extracted assets, **diagnose output** (it contains hostnames, local IPs and the Steam library), or any secret/password/token. This repo is PUBLIC.
   Show reports to the owner; the owner pastes what matters back to the cloud session.
3. Expose services to the tailnet only (`tailscale serve`); never port-forward the router.
4. Log every change in `hostkit/CHANGES.md` (date, what, how to undo). Commit only under `hostkit/` and push `local/5090`.
5. Report each step honestly, including failures. Don't guess driver versions or package names: check the vendor page / `--help`.
6. The owner must sign in to Steam, Rockstar and Tailscale themselves. Never ask for or handle passwords, tokens or Steam Guard codes.

## Order of work
1. **Which OS is this?** Windows -> `hostkit/windows/`. Linux -> `hostkit/linux/`. (Mod injectors and most of the plan need Windows; if this is Linux, ask the owner whether to dual-boot Windows,
   and let the Linux diagnose script's "can Windows go on this box" section answer partitions/UEFI/free space.)
2. **Diagnose** (read-only): run the matching 01 script. Report to the owner: GPU + **driver version** (RTX 50-series needs a recent driver: check NVIDIA's current requirement, and on Linux the open kernel module),
   NVENC/encoder availability, RAM, free disk per drive (GTA V + mods wants ~150 GB free), monitor or dummy HDMI plug attached, wired vs Wi-Fi link speed, Tailscale state, Steam + Rockstar launcher state,
   and whether GTA V is installed and which edition (**Legacy vs Enhanced**; FiveM supports Legacy fully, Enhanced is early access).
3. **Phase 0: streaming host.** Dry-run `02-install-streaming.ps1`, get the owner's OK, then `-Apply` (Tailscale + Sunshine). Walk the owner through sign-in and the Sunshine web UI (local password, add Steam).
   Prove a LAN Moonlight client works (60 fps, controller). Then install Moonlight-Web per its own README (https://github.com/linckosz/moonlight-web, GPL-3.0) and publish it with `03-tailscale-serve.ps1`.
   Needs MagicDNS + HTTPS certificates enabled in the Tailscale admin console (owner's click). Check `tailscale ping <other device>` shows a direct path, not a relay.
4. **Phase 0b: FiveM smoke test (only after 3 works).** Keep a SEPARATE copy of the GTA V Legacy install for modding (never mod the Steam/Rockstar copy; never open GTA Online with mods).
   Install FiveM, run a local-only server (`sv_lan 1`) with an empty resource, and report whether the client needed a Cfx.re login / internet (an open question in the plan).
   Follow docs.fivem.net; do not guess. Read the Creator Platform License notes in `hybrids/outbreak/PLAN.md` first: no Rockstar characters, no cross-title assets, no money mechanics.
5. **Report back** to the owner as a short summary (OS, GPU/driver, free disk, what works, what failed, what you need). Do not push the raw diagnose file.
6. Next, from the cloud: the Outbreak FiveM adapter + NUI colony UI get written against `hybrids/outbreak/API.md` once the sim core lands. Do not start that yourself.

## Handy facts
- Tailscale devices: `michael2026` (Windows PC, GPU unknown), `appdev1` (Linux, 4090), a server with a 5070, and this box. The owner's phone is on the tailnet.
- Site login for the browser games is not in the repo on purpose.
- Tests for the browser-side controller check live at `controllers.html` (open it in Quest Browser / on the tablet to verify pads and Touch controllers).
- If something in the repo contradicts this file, the newer commit on `claude/zealous-bell-jownt4` wins; `git fetch` before you start.
