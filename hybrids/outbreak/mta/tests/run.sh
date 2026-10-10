#!/bin/sh
# Runs the MTA resource's tests. Mock only: nothing here starts MTA:SA (README "What the mocks cannot prove").
#
#   mta/tests/run.sh                 copy checks + the Lua suite under LuaJIT AND Lua 5.4 (+ PUC Lua 5.1 when available) + function_check + the browser test + its Lua replay
#   mta/tests/run.sh --no-browser    skip the Playwright test (no node / chromium)
#   mta/tests/run.sh --with-sim      also run the sim's own suite (about a minute) and the FiveM adapter's suite
#   mta/tests/run.sh --with-server   also run tools/real_server_smoke.sh --quick (the REAL MTA 1.6 Linux server, headless, about 30 s) and tools/phone_e2e.sh (the phone companion on it, about 45 s); server tarballs or a network needed
#   mta/tests/run.sh server peds     only the Lua test files whose name contains one of the words (the browser test is skipped then)
#
# Optional extra runtime: PUC-Rio Lua 5.1.5 is the interpreter MTA really embeds (LuaJIT is 5.1 compatible, not identical). `mta/tools/build_lua51.sh` builds it into ~/.cache;
# then  LUA51=~/.cache/lua-5.1.5/lua-5.1.5/src/lua mta/tests/run.sh  (or put it on the PATH as lua5.1) adds it to the run.
# Reference clones the checks read (read only; the tests say what they skipped when a clone is missing): MTASA_SRC (multitheftauto/mtasa-blue, GPL, default
# /home/user/multitheftauto/mtasa-blue), MTA_RES_SRC (multitheftauto/mtasa-resources, MIT, default /home/user/multitheftauto/mtasa-resources).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
mta="$(cd "$here/.." && pwd)"
outbreak="$(cd "$mta/.." && pwd)"
browser=1
with_sim=0
with_server=0
words=""
for a in "$@"; do
	case "$a" in
		--no-browser) browser=0 ;;
		--with-sim) with_sim=1 ;;
		--with-server) with_server=1 ;;
		*) words="$words $a" ;;
	esac
done
[ -n "$words" ] && browser=0
fail=0
tmp="$(mktemp -d "${TMPDIR:-/tmp}/outbreak-mta.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# step <tail lines> <command...> : runs the command; prints the last lines on success, everything on failure; returns its status (a pipe into tail would hide it)
step() {
	n="$1"; shift
	"$@" > "$tmp/step.out" 2>&1
	rc=$?
	if [ "$rc" = 0 ]; then tail -n "$n" "$tmp/step.out"; else echo "FAIL (exit $rc): $*"; cat "$tmp/step.out"; fi
	return "$rc"
}

echo "=============== copies are in sync (sim + data, shared host modules, vanilla UI, meta.xml, self-test hash recorded)"
for s in sync_sim.sh sync_shared.sh sync_ui.sh; do
	if sh "$mta/tools/$s" check; then :; else echo "FAIL: run mta/tools/$s"; fail=1; fi
done
if luajit "$mta/tools/gen_meta.lua" --check; then :; else echo "FAIL: run luajit mta/tools/gen_meta.lua"; fail=1; fi

runtimes="luajit lua5.4"
if [ -n "${LUA51:-}" ] && [ -x "${LUA51}" ]; then runtimes="$runtimes $LUA51"
elif command -v lua5.1 >/dev/null 2>&1; then runtimes="$runtimes lua5.1"
else echo "(PUC Lua 5.1 not found: run mta/tools/build_lua51.sh and set LUA51 to also test on MTA's real interpreter)"; fi

# every resource file must compile with the real Lua 5.1 compiler (only when a PUC Lua 5.1 build is available; LuaJIT accepts some syntax that 5.1 does not)
luac51=""
if [ -n "${LUA51:-}" ] && [ -x "$(dirname "$LUA51")/luac" ]; then luac51="$(dirname "$LUA51")/luac"; elif command -v luac5.1 >/dev/null 2>&1; then luac51="luac5.1"; fi
if [ -n "$luac51" ]; then
	echo "=============== every resource .lua file compiles with PUC Lua 5.1 ($luac51)"
	bad=0; n=0
	for f in $(find "$mta/outbreak" -name '*.lua'); do n=$((n + 1)); "$luac51" -p "$f" || { echo "FAIL: $f"; bad=1; }; done
	if [ "$bad" = 0 ]; then echo "OK ($n files)"; else fail=1; fi
fi

for rt in $runtimes; do
	if ! command -v "$rt" >/dev/null 2>&1 && [ ! -x "$rt" ]; then echo "FAIL: runtime '$rt' not found"; fail=1; continue; fi
	echo "=============== $rt: self-test hash equals the recorded one (the sim is deterministic on this runtime)"
	if "$rt" "$mta/tools/gen_selftest.lua" --check; then :; else echo "FAIL: selftest hash differs under $rt"; fail=1; fi
	echo "=============== $rt: mock-MTA suite"
	out="$tmp/suite.$(basename "$rt").txt"
	# shellcheck disable=SC2086
	if "$rt" "$here/run.lua" $words > "$out" 2>&1; then
		tail -n 22 "$out"
	else
		echo "FAIL: $rt reported failures; full output follows"
		cat "$out"
		fail=1
	fi
done

echo "=============== function check (every MTA function, event and global the resource uses exists on the side that runs it; checked against mtasa-blue's own definitions)"
for rt in lua5.4 luajit; do
	if "$rt" "$mta/tools/function_check.lua" --quiet; then echo "OK ($rt)"; else rc=$?; if [ "$rc" = 2 ]; then echo "SKIPPED ($rt): the tool could not run (no mtasa-blue clone or luac5.4?)"; else echo "FAIL ($rt)"; "$rt" "$mta/tools/function_check.lua" | tail -n 25; fail=1; fi; fi
done
lua5.4 "$mta/tools/function_check.lua" | sed -n 1,6p

if [ "$browser" = "1" ]; then
	echo "=============== browser test: the unchanged vanilla UI + mta-bridge.js in headless Chromium (needs node + playwright: see the test header)"
	if step 3 luajit "$here/dump_ui_session.lua" "$tmp/session.json" && step 14 node "$here/ui_bridge_test.mjs" "$tmp/session.json" "$tmp/calls.json"; then
		for rt in $runtimes; do
			echo "=============== $rt: the page's recorded calls replayed into the real client + server Lua"
			step 2 "$rt" "$here/replay_ui_calls.lua" "$tmp/calls.json" || fail=1
		done
	else
		fail=1
	fi
	echo "=============== phone bridge: the phone page + ui/phone-bridge.js in a mobile-emulated Chromium against the real phone.lua on the mock (connection loss, restart, 401, ordering)"
	step 6 node "$here/phone_bridge_test.mjs" || fail=1
fi

if [ "$with_server" = "1" ]; then
	echo "=============== the real MTA:SA 1.6 server smoke test (quick)"
	step 30 bash "$mta/tools/real_server_smoke.sh" --quick || fail=1
	echo "=============== the phone companion on the real MTA:SA 1.6 server (curl + a mobile-emulated Chromium, about 45 s)"
	step 30 bash "$mta/tools/phone_e2e.sh" || fail=1
fi

if [ "$with_sim" = "1" ]; then
	echo "=============== the sim's own suite (fast)"
	step 8 sh "$outbreak/tests/run.sh" fast || fail=1
	echo "=============== the FiveM adapter's suite (must stay green: the MTA resource reuses its shared modules)"
	step 6 sh "$outbreak/fivem/tests/run.sh" || fail=1
fi

if [ "$fail" = "0" ]; then echo "ALL GREEN (mta resource, mock only: $runtimes)"; else echo "SOMETHING FAILED"; fi
exit "$fail"
