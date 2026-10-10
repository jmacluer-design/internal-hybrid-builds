#!/bin/sh
# Lists every block of the resource that was ported from a repository WITHOUT a licence (NullSystemWorks/mtadayz, mta-resources/deadwalkers): the owner's private-use-only decision.
#   mta/tools/list_private_blocks.sh            list: file:first-last line, the source repo/path and what it is
#   mta/tools/list_private_blocks.sh --files    only the files that contain such blocks
#   mta/tools/list_private_blocks.sh --check    list, then exit 1 when any block exists (a pre-share gate: "is this resource clean to give away?")
# A block starts with a line   -- BORROWED-PRIVATE (unlicensed upstream, private use only): <repo>/<path> (<note>)   and ends with   -- END BORROWED-PRIVATE.
# mta/THIRD_PARTY.md section "PRIVATE USE ONLY (no licence upstream)" has one row per block.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
res="$(cd "$here/../outbreak" && pwd)"
mode="${1:-list}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
( cd "$res" && find . -name '*.lua' | LC_ALL=C sort | while read -r f; do
	awk -v file="${f#./}" '
		/^[ \t]*-- BORROWED-PRIVATE \(unlicensed upstream, private use only\): / {
			if (open) { printf "%s:%d: UNCLOSED block opened at line %d\n", file, NR, start; bad = 1 }
			open = 1; start = NR; src = $0; sub(/^[ \t]*-- BORROWED-PRIVATE \(unlicensed upstream, private use only\): /, "", src); next }
		/^[ \t]*-- END BORROWED-PRIVATE/ {
			if (!open) { printf "%s:%d: END without a start\n", file, NR; bad = 1 } else { printf "%s:%d-%d\t%s\n", file, start, NR, src; open = 0 } next }
		END { if (open) { printf "%s: UNCLOSED block opened at line %d\n", file, start; bad = 1 } exit bad }
	' "$f" || echo "(marker problem in $f)" >&2
done ) > "$tmp"
n=$(grep -c "$(printf '\t')" "$tmp" || true)
case "$mode" in
	--files) cut -f1 "$tmp" | sed 's/:[0-9-]*$//' | LC_ALL=C sort -u ;;
	*)
		echo "BORROWED-PRIVATE blocks in mta/outbreak ($n): code from repositories with NO licence. Private use only, never redistribute the resource with them."
		echo
		awk -F'\t' '{ printf "  %-34s %s\n", $1, $2 }' "$tmp"
		echo
		cat <<'TXT'
To make the resource shareable (do all of it, then re-run with --check until it exits 0):
  1. For every block above, delete the code between the markers (markers included) and write your own version. (Before the slothbot port the resource had fresh, unborrowed versions of
     client/driver.lua and server/zombies.lua: restore them from your repository history if that version was ever committed.)
  2. Blocks that are only DATA (config zombie_models) can simply be replaced by your own list of skin ids.
  3. Delete the section "PRIVATE USE ONLY (no licence upstream)" of mta/THIRD_PARTY.md and the README warning once --check passes.
  4. Re-run mta/tests/run.sh: the tests pin the behaviour (swing timing, stuck dice, weapon tables ...) of the borrowed blocks, so the tests that fail show exactly what your replacement still has to do.
TXT
		;;
esac
if [ "$mode" = "--check" ] && [ "$n" -gt 0 ]; then exit 1; fi
exit 0
