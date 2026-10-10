#!/bin/sh
# Runs the whole suite under BOTH LuaJIT and Lua 5.4, compares the cross-runtime determinism hashes, and prints the bench for each.
# Fails (non-zero exit) if either runtime fails any test, if a runtime is missing, or if the 30-day state hashes differ.
#
#   tests/run.sh            full suite (about 2-3 minutes)
#   tests/run.sh fast       skip the slow soak/bench files (hash comparison still runs)
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d 2>/dev/null || echo "/tmp/outbreak-run-$$")"
mkdir -p "$tmp"
fail=0
runtimes="luajit lua5.4"

for rt in $runtimes; do
	if ! command -v "$rt" >/dev/null 2>&1; then
		echo "FAIL: runtime '$rt' not found on PATH"
		fail=1
		continue
	fi
	echo "=============== $rt: test suite"
	if "$rt" "$here/run.lua" "$@" > "$tmp/suite.$rt.txt" 2>&1; then
		tail -n 25 "$tmp/suite.$rt.txt"
	else
		echo "FAIL: $rt reported failures; full output follows"
		cat "$tmp/suite.$rt.txt"
		fail=1
	fi
done

echo "=============== cross-runtime determinism (30 in-game days, 1-minute steps, 4 colonies)"
ok_hash=1
for rt in $runtimes; do
	command -v "$rt" >/dev/null 2>&1 || { ok_hash=0; continue; }
	"$rt" "$here/hash_check.lua" > "$tmp/hash.$rt.txt" 2>&1 || ok_hash=0
done
if [ "$ok_hash" = "1" ] && cmp -s "$tmp/hash.luajit.txt" "$tmp/hash.lua5.4.txt"; then
	cat "$tmp/hash.luajit.txt"
	echo "OK: luajit and lua5.4 produce byte-identical hash output"
else
	echo "FAIL: hash output differs between runtimes (or a run failed)"
	echo "--- luajit"; cat "$tmp/hash.luajit.txt" 2>/dev/null
	echo "--- lua5.4"; cat "$tmp/hash.lua5.4.txt" 2>/dev/null
	fail=1
fi

case " $* " in
	*" fast "*) ;;
	*)
		echo "=============== bench (ms per tick, 30 colonists / 12 hordes / 200+ item stacks, 1 tick per game minute)"
		for rt in $runtimes; do command -v "$rt" >/dev/null 2>&1 && "$rt" "$here/bench.lua" 1440; done
		;;
esac

rm -rf "$tmp"
if [ "$fail" = "0" ]; then echo "ALL GREEN (luajit + lua5.4)"; else echo "SOMETHING FAILED"; fi
exit "$fail"
