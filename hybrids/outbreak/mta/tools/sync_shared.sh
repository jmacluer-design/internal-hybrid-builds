#!/bin/sh
# The game-agnostic adapter modules (server core, protocol validators, view models, survival body, json encoder, camera ray maths, placement rules)
# are written once, in fivem/outbreak/shared/, and reused UNCHANGED here: this script makes a byte-identical copy into mta/outbreak/shared/
# (a resource can only read its own folder). `sync_shared.sh check` verifies the copy (used by the tests).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../fivem/outbreak/shared" && pwd)"
res="$here/../outbreak/shared"
mode="${1:-copy}"
rc=0
mkdir -p "$res"
for f in host protocol view survival util json raymath placement; do
	if [ "$mode" = "check" ]; then
		if ! cmp -s "$src/$f.lua" "$res/$f.lua"; then echo "OUT OF SYNC: shared/$f.lua (run mta/tools/sync_shared.sh)"; rc=1; fi
	else
		cp "$src/$f.lua" "$res/$f.lua"
	fi
done
if [ "$mode" = "check" ]; then [ "$rc" = 0 ] && echo "shared copies in sync"; else echo "synced shared (8 files)"; fi
exit $rc
