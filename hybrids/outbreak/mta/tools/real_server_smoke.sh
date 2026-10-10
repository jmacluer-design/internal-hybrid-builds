#!/usr/bin/env bash
# real_server_smoke.sh: runs the Outbreak resource on the REAL MTA:SA 1.6 Linux server (no client, no mock) and asserts from the server log that it loads, passes its self-test,
# keeps the sim consistent, builds a ped budget that holds, saves, restarts and cleans up. Prints PASS / FAIL per check and exits 0 (all PASS), 1 (a check failed) or 2 (could not run).
#
#   mta/tools/real_server_smoke.sh [dest-dir] [--quick]       default dest: $MTA_SMOKE_DIR or $HOME/mta-smoke (its own install: never the real server's directory)
#   --quick   the 30-second variant: shorter waits, a 120-minute fast-forward (about 40 s in all). Run it on the server box after every `git pull`.
# What it does: installs (or reuses) the official server through tools/install_server_linux.sh (MTA_SERVER_TGZ / MTA_BASECONFIG_TGZ may point at tarballs you already have; the sandbox copies in
# /home/user/mta-srv/dl are picked up), moves it to its own ports (MTA_SMOKE_PORT, default 22993 and +2) so it never collides with the real server, wipes ITS saves (only in a dir this script made),
# starts `./mta-server64 -n` headless with a timed console scenario on stdin:
#   outbreak_status, outbreak_autopilot on, outbreak_speed 16, (wait), outbreak_status, outbreak_hash, outbreak_audit, outbreak_peds, outbreak_horde 30 120, outbreak_spawn 40 (test hook: zombies at the
#   base through the real spawn path), outbreak_spawn 200 (the cap must hold), outbreak_peds, outbreak_ff 1440, outbreak_status, outbreak_audit, outbreak_save, `restart outbreak` (cleanup + load the
#   save), outbreak_peds, outbreak_status, shutdown.
# and asserts from the log: Resources: 1 loaded, 0 failed / selftest OK with the recorded hash (twice: start and restart) / audit OK (at least twice) / the sim clock advanced / test zombies have models
# from the config, the tag, no forced syncer, and respect max_materialized and the ped caps / after `restart outbreak` no zombie is left and the saved day was loaded / no ERROR, WARNING, failed, abort
# or timeout line (apart from the harmless owner_email_address warning and the "0 failed" summary) / the server exits with status 0.
# What it can NOT show: anything that needs a client (peds walking, streaming, the CEF page): see README "Unverified until it runs in the real game".
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$(cd "$HERE/../outbreak" && pwd)"
QUICK=0; DEST=""
for a in "$@"; do
	case "$a" in
		--quick) QUICK=1 ;;
		-h|--help) sed -n 2,19p "$0"; exit 0 ;;
		*) DEST="$a" ;;
	esac
done
DEST="${DEST:-${MTA_SMOKE_DIR:-$HOME/mta-smoke}}"
PORT="${MTA_SMOKE_PORT:-22993}"; HTTP_PORT=$((PORT + 2))
SRV="$DEST/multitheftauto_linux_x64"; DM="$SRV/mods/deathmatch"; OUT="$DM/resources/outbreak"
WORK="$DEST/smoke"; STDOUT_LOG="$WORK/server.stdout.log"; FEED="$WORK/feeder.log"
SLOG="$DM/logs/server.log"   # the server's own log: written line by line (its stdout is block-buffered when redirected, so it cannot be polled)
LOG="$SLOG"
if [ "$QUICK" = 1 ]; then WAIT_RUN=8; FF=120; FF_TIMEOUT=90; else WAIT_RUN=25; FF=1440; FF_TIMEOUT=240; fi
HASH="$(sed -n 's/.*hash = "\([0-9a-f]*\)".*/\1/p' "$RES/shared/selftest_data.lua" | head -n 1)"

say() { printf '%s\n' "$*"; }
die() { say "FAIL (cannot run): $*"; exit 2; }
[ "$(uname -m)" = "x86_64" ] || die "needs x86-64 Linux"
[ -n "$HASH" ] || die "no recorded self-test hash in $RES/shared/selftest_data.lua"
command -v timeout >/dev/null || die "coreutils 'timeout' is missing"

# ------------------------------------------------------------------------------------------------------------------------------------------------ install / reuse
mkdir -p "$DEST" "$WORK"
[ -z "${MTA_SERVER_TGZ:-}" ] && [ -f /home/user/mta-srv/dl/server.tar.gz ] && export MTA_SERVER_TGZ=/home/user/mta-srv/dl/server.tar.gz
[ -z "${MTA_BASECONFIG_TGZ:-}" ] && [ -f /home/user/mta-srv/dl/baseconfig.tar.gz ] && export MTA_BASECONFIG_TGZ=/home/user/mta-srv/dl/baseconfig.tar.gz
say "== installing / reusing the MTA:SA Linux server in $DEST (log: $WORK/install.log)"
bash "$HERE/install_server_linux.sh" "$DEST" > "$WORK/install.log" 2>&1 || { tail -n 20 "$WORK/install.log"; die "the installer failed"; }
[ -x "$SRV/mta-server64" ] || die "no server binary at $SRV/mta-server64"
miss="$(ldd "$SRV/mta-server64" 2>&1 | grep 'not found' || true)"
[ -z "$miss" ] || { say "$miss"; die "missing shared libraries (see install.log for the fix)"; }
# its own ports (the real server may be running on this box), no server-browser listing
sed -i -E "s#<serverport>[0-9]+</serverport>#<serverport>$PORT</serverport>#; s#<httpport>[0-9]+</httpport>#<httpport>$HTTP_PORT</httpport>#; s#<ase>1</ase>#<ase>0</ase>#" "$DM/mtaserver.conf"
# a fresh colony every run, but only in an install this script owns
if [ ! -e "$DEST/.mta-smoke" ]; then
	if [ -n "$(ls "$OUT/save"/*.sav 2>/dev/null)" ]; then die "$DEST has saves but was not created by this script: pass another dest (the smoke test wipes its own saves)"; fi
	: > "$DEST/.mta-smoke"
fi
rm -f "$OUT"/save/*.sav 2>/dev/null || true
rm -f "$SLOG" "$DM"/logs/scripts.log 2>/dev/null || true
: > "$STDOUT_LOG"; : > "$FEED"

# ------------------------------------------------------------------------------------------------------------------------------------------------ the scenario
count_log() { local n; n="$(grep -cE -- "$1" "$LOG" 2>/dev/null)"; echo "${n:-0}"; }
await() { # await <pattern> <min count> <timeout s>
	local end=$((SECONDS + $3))
	while [ "$(count_log "$1")" -lt "$2" ]; do
		if [ "$SECONDS" -ge "$end" ]; then echo "timeout waiting for /$1/ (x$2)" >> "$FEED"; return 1; fi
		sleep 0.25
	done
}
STATUS='\] D[0-9]+ [0-9]{2}:[0-9]{2} day'
run() { # run <console command> <pattern its reply contains> [timeout s]
	local mark; mark="$(count_log "$2")"
	echo "$1"
	await "$2" $((mark + 1)) "${3:-20}"
}
feeder() {
	await 'ready to accept connections' 1 90
	await 'selftest OK' 1 30
	run "outbreak_status" "$STATUS"
	run "outbreak_autopilot on" 'autopilot true'
	echo "outbreak_speed 16"; sleep 1
	sleep "$WAIT_RUN"
	run "outbreak_status" "$STATUS"
	run "outbreak_hash" '\[outbreak\] [0-9a-f]{16}$'
	run "outbreak_audit" 'audit (OK|FAILED)'
	run "outbreak_peds" '\] peds [0-9]+/'
	run "outbreak_horde 30 120" '\[outbreak\] (true|false) '
	run "outbreak_spawn 40" '\] spawned [0-9]+ of 40 requested'
	run "outbreak_spawn 200" '\] spawned [0-9]+ of 200 requested'
	run "outbreak_peds" '\] peds [0-9]+/'
	run "outbreak_ff $FF" 'fast-forward done' "$FF_TIMEOUT"
	run "outbreak_status" "$STATUS"
	run "outbreak_audit" 'audit (OK|FAILED)'
	run "outbreak_save" 'saved to slot|save failed'
	# restart: the resource stops (everything it made is destroyed, the colony saved), starts again and loads the save
	echo "restart outbreak"
	await 'selftest OK' 2 60
	sleep 2
	run "outbreak_peds" '\] peds [0-9]+/'
	run "outbreak_status" "$STATUS"
	run "outbreak_audit" 'audit (OK|FAILED)'
	echo "shutdown"
}

say "== starting the server headless on port $PORT ($( [ "$QUICK" = 1 ] && echo quick || echo full ) scenario; polling its log $SLOG)"
T0=$SECONDS
feeder 2>>"$FEED" | timeout $((FF_TIMEOUT + WAIT_RUN + 240)) "$SRV/mta-server64" -n > "$STDOUT_LOG" 2>&1
SERVER_RC=${PIPESTATUS[1]}
ELAPSED=$((SECONDS - T0))
cp "$SLOG" "$WORK/server.log" 2>/dev/null || true
LOG="$WORK/server.log"

# ------------------------------------------------------------------------------------------------------------------------------------------------ assertions
PASS=0; FAILN=0
ok() { say "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { say "  FAIL  $1"; FAILN=$((FAILN + 1)); }
num() { sed -n "s/$1/\\1/p" | head -n "${2:-1}"; }              # first capture of a regex over stdin
minutes() { # "D2 19:39" -> minutes since D1 00:00
	local d h m; d="$(echo "$1" | sed -n 's/.*\] D\([0-9]*\) .*/\1/p')"; h="$(echo "$1" | sed -n 's/.*\] D[0-9]* \([0-9][0-9]\):.*/\1/p')"; m="$(echo "$1" | sed -n 's/.*\] D[0-9]* [0-9][0-9]:\([0-9][0-9]\).*/\1/p')"
	echo $(( (10#$d - 1) * 1440 + 10#$h * 60 + 10#$m ))
}
say
say "== assertions on the server log ($ELAPSED s)"
[ "$SERVER_RC" = 0 ] && ok "the server exited with status 0 after shutdown" || bad "the server exit status was $SERVER_RC (124 = it hung and was killed by the timeout)"
[ "$(count_log 'Resources: 1 loaded, 0 failed')" = 1 ] && ok "Resources: 1 loaded, 0 failed" || bad "no 'Resources: 1 loaded, 0 failed' line"
n="$(count_log "selftest OK: this Lua reproduces the recorded sim hash $HASH")"
[ "$n" -ge 2 ] && ok "selftest OK with the recorded hash $HASH (at start and after the restart: $n times)" || bad "selftest OK with $HASH seen $n times (expected 2)"
n="$(count_log 'audit OK')"; m="$(count_log 'audit FAILED')"
[ "$n" -ge 2 ] && [ "$m" = 0 ] && ok "audit OK $n times, never FAILED" || bad "audit OK $n times, FAILED $m times"
mapfile -t ST < <(grep -E -- "$STATUS" "$LOG")
if [ "${#ST[@]}" -ge 4 ]; then
	a="$(minutes "${ST[0]}")"; b="$(minutes "${ST[1]}")"; c="$(minutes "${ST[2]}")"; d="$(minutes "${ST[3]}")"
	if [ "$QUICK" = 1 ]; then want=20; else want=100; fi
	[ $((b - a)) -ge "$want" ] && ok "the sim clock advanced $((b - a)) game minutes in $WAIT_RUN s at speed 16" || bad "the sim clock advanced only $((b - a)) minutes (wanted >= $want): ${ST[0]} -> ${ST[1]}"
	[ $((c - b)) -ge $((FF - 5)) ] && ok "outbreak_ff $FF advanced $((c - b)) minutes" || bad "outbreak_ff $FF advanced only $((c - b)) minutes"
	[ "$d" -ge "$((c - 60))" ] && ok "the saved colony was loaded again after the restart (day/time $d >= $((c - 60)))" || bad "after the restart the clock is at minute $d but it was $c when saved"
	cols="$(echo "${ST[3]}" | num '.*colonists \([0-9]*\).*')"
	[ "${cols:-0}" -ge 1 ] && ok "colonists survived the restart ($cols)" || bad "no colonists after the restart: ${ST[3]}"
else
	bad "expected 4 status lines, found ${#ST[@]}"
fi
# the test zombies: the real spawn path on the real engine
L40="$(grep -E -- '\] spawned [0-9]+ of 40 requested' "$LOG" | head -n 1)"
if echo "$L40" | grep -qE 'spawned 40 of 40 requested \(ok\): test zombies 40 \| models in config 40/40, tagged 40/40, alive 40/40, syncer-less 40/40'; then
	ok "outbreak_spawn 40: 40 zombie peds created; engine says model in config 40/40, tagged 40/40, alive 40/40, no syncer 40/40"
else bad "outbreak_spawn 40 line: ${L40:-<missing>}"; fi
L200="$(grep -E -- '\] spawned [0-9]+ of 200 requested' "$LOG" | head -n 1)"
got="$(echo "$L200" | num '.*spawned \([0-9]*\) of 200.*')"
hostile="$(echo "$L200" | num '.*hostile peds \([0-9]*\) of 60.*')"
elems="$(echo "$L200" | num '.*ped elements \([0-9]*\).*')"
if [ "${got:-x}" = 20 ] && [ "${hostile:-x}" = 60 ] && echo "$L200" | grep -q 'hostile cap'; then ok "outbreak_spawn 200: only the 20 that fit under max_materialized = 60 were created (hostile cap)"
else bad "outbreak_spawn 200 line: ${L200:-<missing>}"; fi
if [ -n "$elems" ] && [ "$elems" -le 96 ]; then ok "ped elements on the server: $elems (hard cap 96, pool guard 120)"; else bad "ped elements: ${elems:-?}"; fi
mapfile -t PD < <(grep -E -- '\] peds [0-9]+/' "$LOG")
if [ "${#PD[@]}" -ge 3 ]; then
	z2="$(echo "${PD[1]}" | num '.*zombies \([0-9]*\) pending.*')"
	[ "${z2:-0}" = 60 ] && ok "outbreak_peds after the spawns: zombies $z2 (the cap)" || bad "outbreak_peds: ${PD[1]}"
	z3="$(echo "${PD[2]}" | num '.*zombies \([0-9]*\) pending.*')"; e3="$(echo "${PD[2]}" | num '.*ped elements \([0-9]*\)).*')"
	if [ "${z3:-x}" = 0 ] && [ -n "$e3" ] && [ "$e3" -le 16 ]; then ok "after restart outbreak: zombies 0, ped elements $e3 (colonists only): nothing leaked"; else bad "outbreak_peds after the restart: ${PD[2]}"; fi
else bad "expected 3 outbreak_peds lines, found ${#PD[@]}"; fi
# nothing that looks like trouble: MTA's own errors, our error / warn lines, failures, aborts, timeouts
BADLINES="$(cat "$LOG" "$STDOUT_LOG" | grep -iE 'error|warning|failed|abort|timeout|exception|traceback|segmentation' | grep -vE 'owner_email_address|Resources: [0-9]+ loaded, 0 failed' || true)"
if [ -z "$BADLINES" ]; then ok "no ERROR / WARNING / failed / abort / timeout line in the log (the owner_email_address warning is ignored)"
else bad "suspicious log lines:"; echo "$BADLINES" | head -n 12 | sed 's/^/          /'; fi
if [ -s "$FEED" ]; then bad "the scenario script itself reported:"; sed 's/^/          /' "$FEED" | head -n 8; fi

say
if [ "$FAILN" = 0 ]; then
	say "PASS: real MTA 1.6 server smoke test ($PASS checks, $ELAPSED s). Log: $LOG"
	exit 0
fi
say "FAIL: $FAILN of $((PASS + FAILN)) checks failed ($ELAPSED s). The end of the log:"
tail -n 30 "$LOG" | sed 's/^/    | /'
say "Full log: $LOG   install log: $WORK/install.log"
exit 1
