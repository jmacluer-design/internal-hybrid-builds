# Host kit: play real games, hybrids and VR from a browser, off your own GPUs

Why this exists: the real games (GTA, Red Dead, Skyrim, Elden Ring...) and the native hybrid mods (SkyCraft, er-mario,
SkateGM, the MW2 + Minecraft mashup, ArkWeb) only run on a PC that owns the games. This kit turns one Windows PC into a
streaming host and publishes it to your tailnet. The `game.cluerholdings.com` shelf stays the front door.

> Status: written from research, **not yet run on a real machine.** Each step says what to check.

## Phase 0: one command, from your phone (read-only)
Your phone is on Tailscale, so use any remote-desktop app (e.g. Microsoft Remote Desktop) into the Windows PC, open
PowerShell, and run:

    irm https://raw.githubusercontent.com/jmacluer-design/internal-hybrid-builds/claude/zealous-bell-jownt4/hostkit/windows/01-diagnose.ps1 -OutFile $env:TEMP\d.ps1; powershell -ExecutionPolicy Bypass -File $env:TEMP\d.ps1

It changes nothing; it prints GPU, RAM, free disk, Steam games, network speed, and what's installed, and saves
`%USERPROFILE%\hostkit-diagnose.txt`. Paste the output back. (Read the script first if you like: it's 60 lines.)

Or, if Claude Code is on that PC: clone this repo there and say "follow hostkit/AGENTS.md".

## Phase 1: flat streaming (works today, well understood)
1. `02-install-streaming.ps1` (dry run), then `-Apply`: Tailscale + Sunshine via winget.
2. Sunshine web UI (`https://localhost:47990`): local password, add Steam.
3. A Moonlight client pairs on LAN: confirm 60 fps + controller works.
4. Browser client: [Moonlight-Web](https://github.com/linckosz/moonlight-web) (GPL-3.0; WebRTC; Xbox/PS pads with
   rumble). Run it on the host, then `03-tailscale-serve.ps1 -Port <its port>` -> `https://<host>.<tailnet>.ts.net`.
5. Add a "Real games" tile on the shelf that opens that address (tailnet devices only).

## First hybrids to try (each README has the real install steps; all need your own game copies on this PC)
| Hybrid | Needs | Notes |
|---|---|---|
| MW2 + Minecraft ("2010 rust rewrite mashup") | MW2 (Steam) | Prebuilt zip; Minecraft assets download from Mojang on first run (~125 MB) |
| er-mario | Elden Ring + your SM64 US ROM + me3 loader | Offline only, EAC off, separate save |
| SkyCraft | Skyrim SE/AE 1.7.104 + SKSE + Address Library + Minecraft Fabric | Not VR. Needs ~3 GB extra RAM |
| SkateGM | Garry's Mod (x86-64 branch) + your Skate 3 ISO | Installer from its releases |
| OpenRW / DevilutionX | GTA III data / DIABDAT.MPQ | Run locally |

## VR phase (only after Phase 1 works)
- **Reliable:** Quest on the same LAN, via a PC-VR streaming app. For UEVR-injected Unreal games, UEVR supports
  OpenXR and OpenVR runtimes (github.com/praydog/UEVR).
- **Browser VR (experimental):** NVIDIA CloudXR.js streams an OpenXR app to the Quest Browser over WebRTC; Early Access,
  needs HTTPS + a WSS proxy, Wi-Fi 6/6E, < 20 ms, 100+ Mbps; one stream session per OS instance
  (docs.nvidia.com/cloudxr-sdk -> CloudXR.js). Untested with UEVR here.
- **Hybrid + VR:** a host that draws the guest's meshes in its own renderer (SkyCraft style) is stereo for free if the
  host is VR; frame-compositing hybrids need per-eye depth compositing. Nobody has shipped this; it's the research part.

## GPU allocation (your hardware)
- 4090: the VR host (2 NVENC encoders). A 5070 has 1 NVENC. Windows is required for the injectors; the Linux boxes
  stay for services. If the 4090 box is Linux: dual-boot Windows (simplest) or a GPU-passthrough Windows VM (fiddly;
  Sunshine in a passthrough VM wants a monitor or dummy plug).
- Start with whichever Windows machine you have (`michael2026`) to prove the flow, then move it to the 4090.

## Network
Wired ethernet for the host. Tailscale `serve` for HTTPS. Check `tailscale ping <host>` shows a *direct* path, not a
DERP relay, before judging latency.
