#!/bin/sh
# Copies the pure-Lua sim (../../sim) and its data tables (../../data) into the resource folder, because a FiveM
# resource can only read files inside its own directory (LoadResourceFile) and the owner copies fivem/outbreak/ to
# resources/. `sync_sim.sh check` verifies the copy is byte-identical to the originals (used by the tests).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
res="$here/../outbreak"
mode="${1:-copy}"
rc=0
for d in sim data; do
	if [ "$mode" = "check" ]; then
		if ! diff -rq "$root/$d" "$res/$d" >/dev/null 2>&1; then echo "OUT OF SYNC: $d (run fivem/tools/sync_sim.sh)"; diff -rq "$root/$d" "$res/$d" | head -5; rc=1; fi
	else
		rm -rf "$res/$d"; mkdir -p "$res/$d"; cp "$root/$d"/*.lua "$res/$d"/
		echo "synced $d ($(ls "$res/$d" | wc -l) files)"
	fi
done
[ "$mode" = "check" ] && [ "$rc" = 0 ] && echo "sim/data copies in sync"
exit $rc
