#!/usr/bin/env bash
# install_server_linux.sh: one command to get the Outbreak MTA:SA server running on a Linux x86-64 box (e.g. appdev2).
#   bash install_server_linux.sh [dest-dir]            default dest: $HOME/mta-server
#   bash install_server_linux.sh --check [dest-dir]    only report what is installed / what is missing, change nothing
# What it does (idempotent; safe to re-run to update the resource, your saves are kept):
#   1. downloads the official MTA:SA Linux server + base config (https://linux.multitheftauto.com) if not already present
#   2. installs the config ONLY on a fresh install, then makes it private: no server-browser listing, no LAN broadcast, and only `outbreak` auto-starts
#   3. copies the resource (this repo's hybrids/outbreak/mta/outbreak) into mods/deathmatch/resources/outbreak, keeping save/
#   4. checks the server binary's shared libraries and prints the exact fix for anything missing
# Verified here on Ubuntu 24.04 x86-64: the real MTA 1.6 server loaded the resource (0 failed) and ran the sim self-test OK.
# Offline/testing: put MTA_SERVER_TGZ and MTA_BASECONFIG_TGZ in the environment to use tarballs you already have.
set -euo pipefail
CHECK=0; [ "${1:-}" = "--check" ] && { CHECK=1; shift; }
HERE="$(cd "$(dirname "$0")" && pwd)"; RES_SRC="$(cd "$HERE/../outbreak" && pwd)"
DEST="${1:-$HOME/mta-server}"; SRV="$DEST/multitheftauto_linux_x64"; DM="$SRV/mods/deathmatch"
SRV_URL="https://linux.multitheftauto.com/dl/multitheftauto_linux_x64.tar.gz"; CFG_URL="https://linux.multitheftauto.com/dl/baseconfig.tar.gz"
say() { printf '%s\n' "$*"; }
[ "$(uname -m)" = "x86_64" ] || { say "FAIL: needs x86-64 Linux (this is $(uname -m))"; exit 1; }
[ -f "$RES_SRC/meta.xml" ] || { say "FAIL: resource not found at $RES_SRC (run this script from the repo checkout)"; exit 1; }

if [ "$CHECK" = 1 ]; then
  [ -x "$SRV/mta-server64" ] && say "server binary: present ($SRV)" || say "server binary: MISSING"
  [ -f "$DM/mtaserver.conf" ] && say "config: present" || say "config: MISSING"
  [ -f "$DM/resources/outbreak/meta.xml" ] && say "resource: installed" || say "resource: NOT installed"
  grep -q 'resource src="outbreak"' "$DM/mtaserver.conf" 2>/dev/null && say "autostart: outbreak" || say "autostart: not set"
  [ -x "$SRV/mta-server64" ] && { miss="$(ldd "$SRV/mta-server64" 2>&1 | grep 'not found' || true)"; [ -n "$miss" ] && say "missing libraries:\n$miss" || say "libraries: all found"; }
  exit 0
fi

command -v curl >/dev/null || { say "FAIL: curl is needed (sudo apt install -y curl)"; exit 1; }
mkdir -p "$DEST/dl"
if [ ! -x "$SRV/mta-server64" ]; then
  say "== downloading the official MTA:SA Linux server"
  if [ -n "${MTA_SERVER_TGZ:-}" ]; then cp "$MTA_SERVER_TGZ" "$DEST/dl/server.tar.gz"; else curl -fSL --retry 3 -o "$DEST/dl/server.tar.gz" "$SRV_URL"; fi
  LIST="$(tar -tzf "$DEST/dl/server.tar.gz" 2>/dev/null || true)"   # (not piped into grep -q: SIGPIPE + pipefail would fail it)
  case "$LIST" in *multitheftauto_linux_x64/mta-server64*) ;; *) say "FAIL: the download is not the MTA server tarball"; exit 1;; esac
  tar -xzf "$DEST/dl/server.tar.gz" -C "$DEST"
fi
mkdir -p "$DM/resources"
if [ ! -f "$DM/mtaserver.conf" ]; then
  say "== fresh install: base config, made private (no browser listing, no LAN broadcast, only 'outbreak' auto-starts)"
  if [ -n "${MTA_BASECONFIG_TGZ:-}" ]; then cp "$MTA_BASECONFIG_TGZ" "$DEST/dl/baseconfig.tar.gz"; else curl -fSL --retry 3 -o "$DEST/dl/baseconfig.tar.gz" "$CFG_URL"; fi
  tar -xzf "$DEST/dl/baseconfig.tar.gz" -C "$DEST/dl"
  for f in "$DEST"/dl/baseconfig/*; do [ -e "$DM/$(basename "$f")" ] || cp "$f" "$DM/"; done   # (no cp -n/--update: differs between coreutils builds)
  sed -i -E 's#<ase>1</ase>#<ase>0</ase>#; s#<donotbroadcastlan>0</donotbroadcastlan>#<donotbroadcastlan>1</donotbroadcastlan>#; /<resource src=/d' "$DM/mtaserver.conf"
  sed -i 's#</config>#    <resource src="outbreak" startup="1" protected="0"/>\n</config>#' "$DM/mtaserver.conf"
fi
grep -q 'resource src="outbreak"' "$DM/mtaserver.conf" || sed -i 's#</config>#    <resource src="outbreak" startup="1" protected="0"/>\n</config>#' "$DM/mtaserver.conf"
say "== installing the resource (your saves are kept)"
OUT="$DM/resources/outbreak"; KEEP=""
if [ -d "$OUT/save" ]; then KEEP="$(mktemp -d)"; cp -a "$OUT/save/." "$KEEP/"; fi
rm -rf "$OUT"; cp -a "$RES_SRC" "$OUT"
[ -n "$KEEP" ] && { mkdir -p "$OUT/save"; cp -a "$KEEP/." "$OUT/save/"; rm -rf "$KEEP"; }
miss="$(ldd "$SRV/mta-server64" 2>&1 | grep 'not found' || true)"
if [ -n "$miss" ]; then
  say "== missing shared libraries:"; say "$miss"
  say "   fix (Ubuntu/Debian): sudo apt install -y libncurses6 libtinfo6 libssl3 zlib1g; if 'libtinfo.so.5' or 'libncursesw.so.5' is named,"
  say "   link the new one: sudo ln -s /lib/x86_64-linux-gnu/libtinfo.so.6 /lib/x86_64-linux-gnu/libtinfo.so.5   (same for libncursesw.so.6 -> .5)"
fi
cat <<EOF

DONE. Start the server (use tmux so it survives your SSH session; the console is where the outbreak_* commands go):
    tmux new -s mta 'cd "$SRV" && ./mta-server64'        # detach: Ctrl-b d      re-attach: tmux attach -t mta
    (no tmux? foreground:  cd "$SRV" && ./mta-server64    or headless:  ./mta-server64 -n)
You should see:   [outbreak] info: selftest OK: this Lua reproduces the recorded sim hash 449ba8f9380b6128
Then try in the console:  outbreak_status    outbreak_autopilot on    outbreak_speed 16    outbreak_audit
From your PC (MTA:SA client): Quick Connect to <this box's tailscale IP>:22003 . Open UDP 22003 and TCP 22005 for the tailnet (README section 3).
Re-run this script any time to update the resource after a git pull; check state with:  bash $0 --check "$DEST"
EOF
