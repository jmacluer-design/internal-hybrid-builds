#!/bin/sh
# Reuses the finished vanilla NUI (fivem/outbreak/ui) UNCHANGED in the MTA resource:
#   * every file of the vanilla ui/ folder is copied BYTE-IDENTICALLY into mta/outbreak/ui/ (index.html, css/, js/, fonts/);
#   * mta/outbreak/ui/mta.html (the page the MTA browser loads) is GENERATED from the vanilla index.html by inserting exactly one line,
#     <script src="mta-bridge.js"></script>, before the first vanilla script, so the bridge runs before js/core.js;
#   * mta/outbreak/ui/mta-bridge.js is our own file (not copied, not touched by this script).
# `sync_ui.sh check` verifies all of that without writing (used by the tests).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../fivem/outbreak/ui" && pwd)"
dst="$here/../outbreak/ui"
mode="${1:-copy}"
bridge_line='<script src="mta-bridge.js"></script>'

generate() { # stdout = mta.html
	awk -v line="$bridge_line" '
		!done && /<script src="js\/core.js"><\/script>/ { print line; done = 1 }
		{ print }
		END { if (!done) exit 3 }
	' "$src/index.html"
}

if [ "$mode" = "check" ]; then
	rc=0
	if ! diff -rq -x mta.html -x mta-bridge.js "$src" "$dst" >/dev/null 2>&1; then echo "OUT OF SYNC: ui/ differs from fivem/outbreak/ui"; diff -rq -x mta.html -x mta-bridge.js "$src" "$dst" | head -8; rc=1; fi
	tmp="$(mktemp)"
	if generate > "$tmp" && [ -f "$dst/mta.html" ] && cmp -s "$tmp" "$dst/mta.html"; then :; else echo "OUT OF SYNC: ui/mta.html is not the generated entry page"; rc=1; fi
	rm -f "$tmp"
	[ -f "$dst/mta-bridge.js" ] || { echo "MISSING: ui/mta-bridge.js"; rc=1; }
	[ "$rc" = 0 ] && echo "ui copy in sync (vanilla files byte-identical, mta.html generated, mta-bridge.js present)"
	exit $rc
fi

mkdir -p "$dst"
keep="$(mktemp)"; [ -f "$dst/mta-bridge.js" ] && cp "$dst/mta-bridge.js" "$keep" || : > "$keep"
find "$dst" -mindepth 1 -maxdepth 1 ! -name mta-bridge.js -exec rm -rf {} +
cp -R "$src"/. "$dst"/
generate > "$dst/mta.html"
[ -s "$keep" ] && cp "$keep" "$dst/mta-bridge.js"
rm -f "$keep"
echo "synced ui ($(find "$dst" -type f | wc -l) files, mta.html generated)"
