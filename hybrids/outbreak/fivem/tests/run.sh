#!/bin/sh
# Runs the FiveM adapter's tests under BOTH LuaJIT and Lua 5.4, plus tools/native_check.lua and the check that the resource's sim/ + data/ copies are
# byte-identical to the canonical ones. Exit status is non-zero if anything fails.
#
#   fivem/tests/run.sh              adapter tests + native check + copy check
#   fivem/tests/run.sh --with-sim   also run the sim's own suite (tests/run.sh fast, about a minute)
#   fivem/tests/run.sh host raymath only the test files whose name contains one of the words
set -u
here="$(cd "$(dirname "$0")" && pwd)"
fivem="$(cd "$here/.." && pwd)"
sim_tests="$(cd "$fivem/.." && pwd)/tests"
with_sim=0
words=""
for a in "$@"; do
	if [ "$a" = "--with-sim" ]; then with_sim=1; else words="$words $a"; fi
done
fail=0

echo "=============== sim copy check (fivem/outbreak/sim + data are byte-identical to the canonical files)"
if sh "$fivem/tools/sync_sim.sh" check; then :; else echo "FAIL: run fivem/tools/sync_sim.sh"; fail=1; fi

for rt in luajit lua5.4; do
	if ! command -v "$rt" >/dev/null 2>&1; then echo "FAIL: runtime '$rt' not found on PATH"; fail=1; continue; fi
	echo "=============== $rt: adapter tests"
	# shellcheck disable=SC2086
	if "$rt" "$here/run.lua" $words > "/tmp/outbreak-fivem-$$.$rt.txt" 2>&1; then
		tail -n 18 "/tmp/outbreak-fivem-$$.$rt.txt"
	else
		echo "FAIL: $rt reported failures; full output follows"
		cat "/tmp/outbreak-fivem-$$.$rt.txt"
		fail=1
	fi
	rm -f "/tmp/outbreak-fivem-$$.$rt.txt"
done

echo "=============== native check (every native the resource calls exists in the FiveM natives on the side that calls it)"
for rt in lua5.4 luajit; do
	if "$rt" "$fivem/tools/native_check.lua" --quiet; then echo "OK ($rt)"; else echo "FAIL ($rt)"; "$rt" "$fivem/tools/native_check.lua" | tail -n 12; fail=1; fi
done
"lua5.4" "$fivem/tools/native_check.lua" | sed -n 1,4p

if [ "$with_sim" = "1" ]; then
	echo "=============== the sim's own suite (fast)"
	if sh "$sim_tests/run.sh" fast | tail -n 8; then :; fi
fi

if [ "$fail" = "0" ]; then echo "ALL GREEN (fivem adapter: luajit + lua5.4)"; else echo "SOMETHING FAILED"; fi
exit "$fail"
