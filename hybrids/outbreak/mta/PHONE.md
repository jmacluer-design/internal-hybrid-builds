# Phone: three ways to look after the Outbreak colony from your phone

Private build, for your own server and your own tailnet. Read the section **3a** of [`README.md`](README.md) for the one that is built and tested (the phone companion); this file puts the three side by side and
covers the third, streaming the PC, which is research only.

| | 1. The game on a PC | 2. **Phone companion** (built) | 3. **Stream the PC** (Sunshine + Moonlight) |
|---|---|---|---|
| What you see | the 3D world + the colony UI | the colony UI, 2D tactical map, live from the server | the real game picture, on the phone |
| Needs | GTA + MTA client on a PC | a phone browser on Tailscale, an MTA account | a Windows PC that owns GTA, running MTA + Sunshine; Moonlight on the phone |
| GTA / client needed | yes | **no** | yes (on the PC) |
| Input | mouse + keyboard | touch (bottom sheets, pinch, long-press) | Moonlight turns touch into a mouse / an on-screen pad; the desktop UI is small on a phone screen |
| Bandwidth / latency | LAN | a few KB per second, polling | 10 to 50 Mbit/s video, latency matters |
| Works with the PC off | n/a | yes (the sim runs on the server) | no |
| State | never run in a real client | verified on the real MTA 1.6 server with a mobile-emulated Chromium; **never on a physical phone** | **not run**: the host kit is "written from research, not yet run on a real machine" |

## Option 2 in one screen

`bash mta/tools/phone_acl.sh <mods/deathmatch/acl.xml>`, restart the server, `addaccount phone <password>` in the server console, then open `http://<tailscale-ip>:22005/outbreak/` on the phone and log in. Add it to the
home screen. Details, security notes and what it cannot do: README section 3a. Check it any time with `bash mta/tools/phone_e2e.sh` (about 45 s).

## Option 3: stream the game with Sunshine / Moonlight from the Windows PC

The repository's host kit does this for any game; start there: [`hostkit/README.md`](../../../hostkit/README.md) (at the repository root) ("Phase 1: flat streaming"; scripts in `hostkit/windows/`). For Outbreak:

1. On the Windows PC (it owns GTA San Andreas and has the MTA client installed; on the same tailnet): `hostkit/windows/02-install-streaming.ps1` (dry run), then `-Apply`: Tailscale + Sunshine via winget.
2. Sunshine's web UI (`https://localhost:47990`): set the local password; add an application that starts the MTA client (`Multi Theft Auto.exe`), or add Steam / the desktop.
3. On the phone: the **Moonlight** app (iOS / Android); add the PC by its Tailscale IP, pair with the PIN Sunshine shows. Set the stream to 1080p60 (or lower for mobile data) and turn the bitrate to what the link
   sustains. `tailscale ping <pc>` should say *direct*, not DERP, before you judge latency.
4. In the stream, connect the MTA client to the server (`mtasa://<server tailscale ip>:22003`) and play as in README section 4. The colony UI is the desktop layout at the stream's resolution: raise the UI scale in the
   Menu (Settings, up to 150 %) or use option 2 on the same phone for management and the stream only for the 3D view. A browser client exists too (Moonlight-Web, `hostkit/windows/03-tailscale-serve.ps1` to publish it over
   HTTPS on the tailnet), see the host kit.

**Unverified, all of it:** that Sunshine / Moonlight run well on your PC and phone, MTA's client under Sunshine (window focus, the cursor, exclusive fullscreen), the colony UI's mouse and keyboard model through
Moonlight's touch-to-mouse emulation (right-click and drag-select are awkward; the on-screen keyboard is needed for F6 / hotkeys), end-to-end latency over Tailscale (a relayed DERP path is unusable for a fast game but fine
for a colony manager), GTA / MTA licensing questions of streaming your own copy to your own devices (private use only; not a redistribution), and battery / heat on the phone. The phone companion (option 2) avoids
every one of these by not running the game on the phone's side at all.

## Which one when

* Checking on the colony, giving orders, changing priorities, building, from anywhere, with the PC off: **option 2**.
* You want to *see* the world and walk about in it from the phone: **option 3**, on a good link.
* Playing properly: **option 1**.
