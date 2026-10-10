#!/bin/sh
# Reuses the finished vanilla NUI (fivem/outbreak/ui) UNCHANGED in the MTA resource:
#   * every file of the vanilla ui/ folder is copied BYTE-IDENTICALLY into mta/outbreak/ui/ (index.html, css/, js/, fonts/);
#   * mta/outbreak/ui/mta.html (the page the MTA browser loads in the GTA client) is GENERATED from the vanilla index.html by inserting exactly one line,
#     <script src="mta-bridge.js"></script>, before the first vanilla script, so the bridge runs before js/core.js;
#   * mta/outbreak/ui/phone.html (the page a PHONE browser loads from MTA's HTTP server at /outbreak/) is GENERATED the same way: <script src="phone-bridge.js"> before js/core.js, plus
#     <base href="/outbreak/ui/"> (the default page is served at /outbreak/, the assets live under /outbreak/ui/), the home-screen title / icons / manifest, a plain <title>, and the css files AND the
#     scripts (phone-bridge.js first) INLINED: MTA's HTTP server labels every .css file application/octet-stream and browsers refuse such a stylesheet; with the scripts inlined too the page
#     does not depend on any MIME type and costs one request instead of twenty (only the fonts, the icons and the manifest are fetched separately);
#   * the MTA-only files are our own and are neither copied nor touched by this script: mta-bridge.js, phone-bridge.js, phone-manifest.json, phone-icon-*.png (mta/tools/gen_phone_icons.py).
# `sync_ui.sh check` verifies all of that without writing (used by the tests).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../../fivem/outbreak/ui" && pwd)"
dst="$here/../outbreak/ui"
mode="${1:-copy}"
bridge_line='<script src="mta-bridge.js"></script>'
phone_line='<script src="phone-bridge.js"></script>'
OWN='mta-bridge.js phone-bridge.js phone-manifest.json phone-icon-180.png phone-icon-192.png phone-icon-512.png'

generate() { # stdout = mta.html
	awk -v line="$bridge_line" '
		!done && /<script src="js\/core.js"><\/script>/ { print line; done = 1 }
		{ print }
		END { if (!done) exit 3 }
	' "$src/index.html"
}

generate_phone() { # stdout = phone.html: everything inlined except the fonts, the icons and the manifest
	awk -v bridge="$dst/phone-bridge.js" -v dir="$src/" '
		!b && /<meta charset="utf-8">/ { print; print "<base href=\"/outbreak/ui/\">"; b = 1; next }
		/<link rel="stylesheet" href="css\/[a-z]+\.css">/ { # the MTA HTTP server sends .css as application/octet-stream, browsers refuse such a stylesheet: inline them
			match($0, /css\/[a-z]+\.css/); f = dir substr($0, RSTART, RLENGTH); print "<style>"
			while ((getline l < f) > 0) { gsub(/\.\.\/fonts\//, "fonts/", l); print l }
			close(f); print "</style>"; s++; next
		}
		!t && /<title>/ { print "<title>Outbreak</title>"; t = 1; next }
		!l && /<link rel="icon" href="data:,">/ {
			print "<link rel=\"icon\" type=\"image/png\" href=\"phone-icon-192.png\">"
			print "<link rel=\"apple-touch-icon\" href=\"phone-icon-180.png\">"
			print "<link rel=\"manifest\" href=\"phone-manifest.json\" crossorigin=\"use-credentials\">"
			print "<meta name=\"apple-mobile-web-app-title\" content=\"Outbreak\">"
			l = 1; next
		}
		/<script src="js\/[a-z]+\.js"><\/script>/ { # scripts are inlined too: no dependence on the MIME type the server gives them, one request instead of twenty
			if (!d) { print "<script>"; while ((getline l < bridge) > 0) print l; close(bridge); print "</script>"; d = 1 }
			match($0, /js\/[a-z]+\.js/); f = dir substr($0, RSTART, RLENGTH); print "<script>"
			while ((getline l < f) > 0) print l
			close(f); print "</script>"; j++; next
		}
		{ print }
		END { if (!b || !t || !l || !d || s < 4 || j < 10) exit 3 }
	' "$src/index.html"
}

own_excludes() { for f in $OWN mta.html phone.html; do printf ' -x %s' "$f"; done; }

if [ "$mode" = "check" ]; then
	rc=0
	# shellcheck disable=SC2046
	if ! diff -rq $(own_excludes) "$src" "$dst" >/dev/null 2>&1; then echo "OUT OF SYNC: ui/ differs from fivem/outbreak/ui"; diff -rq $(own_excludes) "$src" "$dst" | head -8; rc=1; fi
	tmp="$(mktemp)"
	if generate > "$tmp" && [ -f "$dst/mta.html" ] && cmp -s "$tmp" "$dst/mta.html"; then :; else echo "OUT OF SYNC: ui/mta.html is not the generated entry page"; rc=1; fi
	if generate_phone > "$tmp" && [ -f "$dst/phone.html" ] && cmp -s "$tmp" "$dst/phone.html"; then :; else echo "OUT OF SYNC: ui/phone.html is not the generated phone entry page"; rc=1; fi
	rm -f "$tmp"
	for f in $OWN; do [ -f "$dst/$f" ] || { echo "MISSING: ui/$f"; rc=1; }; done
	[ "$rc" = 0 ] && echo "ui copy in sync (vanilla files byte-identical, mta.html + phone.html generated, bridges / manifest / icons present)"
	exit $rc
fi

mkdir -p "$dst"
keep="$(mktemp -d)"
for f in $OWN; do [ -f "$dst/$f" ] && cp "$dst/$f" "$keep/$f" || :; done
find "$dst" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -R "$src"/. "$dst"/
for f in $OWN; do [ -f "$keep/$f" ] && cp "$keep/$f" "$dst/$f" || :; done
rm -rf "$keep"
generate > "$dst/mta.html"
generate_phone > "$dst/phone.html"
echo "synced ui ($(find "$dst" -type f | wc -l) files, mta.html + phone.html generated)"
