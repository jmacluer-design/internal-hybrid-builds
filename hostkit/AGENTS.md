# Instructions for a local Claude Code session on the Windows game host

You are running on the owner's own Windows PC (the "host"), which has their games installed. Goal: make this PC a
streaming game host reachable from the owner's tailnet, so real games (and hybrid mods) play in a browser tab,
a tablet or a TV, and later in a Quest headset. Read `hostkit/README.md` first.

## Rules
- Diagnose before changing anything: run `hostkit/windows/01-diagnose.ps1` and read the output.
- Ask before: installing or updating GPU drivers, changing Windows settings, opening firewall ports beyond what
  Sunshine's installer adds, or deleting anything. Prefer dry runs (`02-install-streaming.ps1` without `-Apply`).
- Never commit or upload game files, ROMs, ISOs, or extracted assets. Never put secrets in the repo.
- Expose services to the tailnet only (`tailscale serve`); do not port-forward the router.
- Mods read the owner's own game installs on this machine; nothing here is hosted publicly.
- Log what you changed in `hostkit/CHANGES.md` (date, what, how to undo).

## Order of work
1. Diagnose (01). Report GPU, free disk, Steam library, network adapter, what is already installed.
2. Install Tailscale + Sunshine (02 with `-Apply`, after the owner agrees). Walk the owner through sign-in and the
   Sunshine web UI (set a local password, add Steam as an app).
3. Prove flat streaming works on the LAN with a Moonlight client, then publish the browser client with
   `03-tailscale-serve.ps1`. Read https://github.com/linckosz/moonlight-web (GPL-3.0) for its install steps first
   and follow its README rather than guessing.
4. Test one hybrid end to end (see README "First hybrids"), using the mod's own README for install steps.
5. VR only after 1-4 work: see README "VR phase". Test with the Quest on the same LAN first.

Report each step's result honestly, including what failed.
