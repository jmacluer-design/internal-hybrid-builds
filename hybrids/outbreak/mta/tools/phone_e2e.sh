#!/usr/bin/env bash
# phone_e2e.sh: the PHONE COMPANION against the REAL MTA:SA 1.6 Linux server, headless, no GTA client. Starts the official server (its own install and ports, like real_server_smoke.sh),
# adds the ACL groups (tools/phone_acl.sh), creates the phone accounts in the server console (`addaccount`), then drives the HTTP port two ways:
#   * curl: the login (401 without / with a wrong password / for an account the ACL does not allow), the page, the call interface, the CSRF header and Origin checks, a look-only account's
#     refusals, an order from a control account, and what MTA's HTTP server hands out WITHOUT a login (the sim and server code must answer 404);
#   * mta/tests/phone_e2e.mjs: a mobile-emulated Chromium (touch, DPR 3, httpCredentials) that loads http://<host>:<http port>/outbreak/ over a second loopback address (so the server's HTTP
#     flood guard is NOT bypassed), reads what the UI shows, changes a work priority and places a blueprint BY TOUCH, opens the Director, looks at it in landscape, and tries to change something
#     with the look-only login. Screenshots of the live phone UI go to screenshots/mobile/live-*.png.
# and compares everything with what the server's own console says (outbreak_status / outbreak_hash / outbreak_prio / outbreak_phone), with the sim paused so the numbers cannot move.
#
#   mta/tools/phone_e2e.sh [dest-dir]      default dest: $MTA_PHONE_DIR or $HOME/mta-phone (its own install, never the real server's directory; about 2 minutes)
# Exit 0 = all PASS, 1 = a check failed, 2 = could not run. Needs: the official server tarballs (MTA_SERVER_TGZ / MTA_BASECONFIG_TGZ, or the sandbox copies in /home/user/mta-srv/dl), curl,
# python3 and, for the browser half, node + Playwright + Chromium (the paths of preview/tests/lib.mjs; override with CHROMIUM=...). Without them only the curl half runs and says so.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$(cd "$HERE/../outbreak" && pwd)"
OUTBREAK="$(cd "$HERE/../.." && pwd)"
DEST="${1:-${MTA_PHONE_DIR:-$HOME/mta-phone}}"
PORT="${MTA_PHONE_PORT:-22983}"; HTTP_PORT=$((PORT + 2))
SRV="$DEST/multitheftauto_linux_x64"; DM="$SRV/mods/deathmatch"
WORK="$DEST/e2e"; SLOG="$DM/logs/server.log"; STDOUT_LOG="$WORK/server.stdout.log"; FEED="$WORK/feeder.log"
URL="http://127.0.0.1:$HTTP_PORT/outbreak"          # curl: 127.0.0.1 is excluded from the flood guard (http_dos_exclude) because curl opens a connection per call
BURL="http://127.0.0.2:$HTTP_PORT/outbreak/"         # the browser: another loopback address, NOT excluded: the default HTTP flood guard applies to the real polling
SHOTS="$OUTBREAK/screenshots/mobile"
PW_PHONE='e2e-phone-pass-1'; PW_VIEW='e2e-view-pass-1'; PW_NOBODY='e2e-nobody-pass-1'
HASH="$(sed -n 's/.*hash = "\([0-9a-f]*\)".*/\1/p' "$RES/shared/selftest_data.lua" | head -n 1)"
say() { printf '%s\n' "$*"; }
die() { say "FAIL (cannot run): $*"; exit 2; }
[ "$(uname -m)" = "x86_64" ] || die "needs x86-64 Linux"
command -v curl >/dev/null || die "curl is missing"; command -v python3 >/dev/null || die "python3 is missing"; command -v timeout >/dev/null || die "coreutils 'timeout' is missing"
BROWSER=1; command -v node >/dev/null || BROWSER=0
[ -f /opt/node-tools/node_modules/playwright/index.mjs ] || BROWSER=0

# ------------------------------------------------------------------------------------------------------------------------------------------------ install / configure
mkdir -p "$DEST" "$WORK" "$SHOTS"
[ -z "${MTA_SERVER_TGZ:-}" ] && [ -f /home/user/mta-srv/dl/server.tar.gz ] && export MTA_SERVER_TGZ=/home/user/mta-srv/dl/server.tar.gz
[ -z "${MTA_BASECONFIG_TGZ:-}" ] && [ -f /home/user/mta-srv/dl/baseconfig.tar.gz ] && export MTA_BASECONFIG_TGZ=/home/user/mta-srv/dl/baseconfig.tar.gz
say "== installing / reusing the MTA:SA Linux server in $DEST (log: $WORK/install.log)"
bash "$HERE/install_server_linux.sh" "$DEST" > "$WORK/install.log" 2>&1 || { tail -n 20 "$WORK/install.log"; die "the installer failed"; }
[ -x "$SRV/mta-server64" ] || die "no server binary at $SRV/mta-server64"
miss="$(ldd "$SRV/mta-server64" 2>&1 | grep 'not found' || true)"; [ -z "$miss" ] || { say "$miss"; die "missing shared libraries (see install.log)"; }
if [ ! -e "$DEST/.mta-phone" ]; then
	if [ -n "$(ls "$DM/resources/outbreak/save"/*.sav 2>/dev/null)" ]; then die "$DEST has saves but was not created by this script: pass another dest (this test wipes its own saves and accounts)"; fi
	: > "$DEST/.mta-phone"
fi
sed -i -E "s#<serverport>[0-9]+</serverport>#<serverport>$PORT</serverport>#; s#<httpport>[0-9]+</httpport>#<httpport>$HTTP_PORT</httpport>#; s#<ase>1</ase>#<ase>0</ase>#; s#<http_dos_exclude>[^<]*</http_dos_exclude>#<http_dos_exclude>127.0.0.1</http_dos_exclude>#" "$DM/mtaserver.conf"
[ -f "$DM/acl.xml.bak-outbreak" ] && cp "$DM/acl.xml.bak-outbreak" "$DM/acl.xml"   # start from the pristine ACL every run
bash "$HERE/phone_acl.sh" "$DM/acl.xml" > "$WORK/acl.log" 2>&1 || { cat "$WORK/acl.log"; die "phone_acl.sh failed"; }
rm -f "$DM/internal.db" "$DM/resources/outbreak/save"/*.sav "$SLOG" "$DM/logs/scripts.log" 2>/dev/null || true   # fresh accounts and a fresh colony (this install is ours)
: > "$STDOUT_LOG"; : > "$FEED"; : > "$WORK/curl.env"; rm -f "$WORK/result.json"

# ------------------------------------------------------------------------------------------------------------------------------------------------ the scenario
LOG="$SLOG"
count_log() { local n; n="$(grep -cE -- "$1" "$LOG" 2>/dev/null)"; echo "${n:-0}"; }
await() { # await <pattern> <min count> <timeout s>
	local end=$((SECONDS + $3))
	while [ "$(count_log "$1")" -lt "$2" ]; do
		if [ "$SECONDS" -ge "$end" ]; then echo "timeout waiting for /$1/ (x$2)" >> "$FEED"; return 1; fi
		sleep 0.25
	done
}
STATUS='\] D[0-9]+ [0-9]{2}:[0-9]{2} day'
run() { local mark; mark="$(count_log "$2")"; echo "$1"; await "$2" $((mark + 1)) "${3:-20}"; }
rec() { printf '%s=%q\n' "$1" "$2" >> "$WORK/curl.env"; }
code() { curl -s -o /dev/null -m 15 -w '%{http_code}' "$@"; }
# POST to the call interface: prints the HTTP code on the last line, the body above it
post() { local cred="$1" body="$2"; shift 2; local auth=(); [ "$cred" != "-" ] && auth=(-u "$cred"); curl -s -m 15 -w '\n%{http_code}' "${auth[@]}" -X POST -H 'Content-Type: application/json' "$@" -d "$body" "$URL/call/phoneApi"; }
inner() { python3 -c 'import sys,json; t=sys.stdin.read().rsplit("\n",1)[0]; print(json.loads(t)[0] if t.strip().startswith("[") else "NONJSON")'; }
jx() { python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$1" 2>/dev/null; }
lastline() { tail -n 1; }
SID=e2ecurlsession001; SIDV=e2ecurlview000001
H1='X-Outbreak-Phone: 1'

curl_checks() {
	# -- the login: MTA's HTTP server, Basic auth, ACL
	rec C_page_anon "$(code "$URL/")"
	rec C_page_noslash "$(code "$URL")"
	rec C_page_badpw "$(code -u "phone:wrong-password" "$URL/")"
	rec C_page_nobody "$(code -u "nobody:$PW_NOBODY" "$URL/")"
	rec C_page_phone "$(code -u "phone:$PW_PHONE" "$URL/")"
	rec C_page_view "$(code -u "phoneview:$PW_VIEW" "$URL/")"
	curl -s -m 15 -u "phone:$PW_PHONE" "$URL/" > "$WORK/page.html"
	rec C_page_has_bridge "$(grep -c 'phone-bridge.js' "$WORK/page.html")"
	rec C_page_has_base "$(grep -c '<base href="/outbreak/ui/">' "$WORK/page.html")"
	rec C_page_inlined_css "$(grep -c '<style>' "$WORK/page.html")"
	rec C_page_phone_slash "$(code -u "phone:$PW_PHONE" "$URL/phone/")"
	rec C_api_anon "$(post - "[\"ready\",\"$SID\"]" -H "$H1" | lastline)"
	rec C_api_badpw "$(post "phone:wrong-password" "[\"ready\",\"$SID\"]" -H "$H1" | lastline)"
	rec C_api_nobody "$(post "nobody:$PW_NOBODY" "[\"ready\",\"$SID\"]" -H "$H1" | lastline)"
	# -- the call interface with a valid login
	local r
	r="$(post "phone:$PW_PHONE" "[\"ready\",\"$SID\"]")"; rec C_api_nohdr_code "$(echo "$r" | lastline)"; rec C_api_nohdr_err "$(echo "$r" | inner | jx "d['error']")"
	r="$(post "phone:$PW_PHONE" "[\"ready\",\"$SID\"]" -H "$H1" -H "Origin: http://evil.example")"; rec C_api_origin_err "$(echo "$r" | inner | jx "d['error']")"
	r="$(post "phone:$PW_PHONE" "[\"ready\",\"$SID\"]" -H "$H1" -H "Origin: http://127.0.0.1:$HTTP_PORT")"
	rec C_api_ready_code "$(echo "$r" | lastline)"; echo "$r" | inner > "$WORK/ready.json"
	rec C_api_ready_role "$(jx "d['role']" < "$WORK/ready.json")"
	rec C_api_ready_actions "$(jx "','.join(m['action'] for m in d['msgs'])" < "$WORK/ready.json")"
	rec C_api_colonists "$(jx "len([m for m in d['msgs'] if m['action']=='state'][0]['data']['colonists'])" < "$WORK/ready.json")"
	r="$(post "phoneview:$PW_VIEW" "[\"ready\",\"$SIDV\"]" -H "$H1")"; rec C_view_role "$(echo "$r" | inner | jx "d['role']")"
	local cid work lv
	cid="$(jx "[m for m in d['msgs'] if m['action']=='state'][0]['data']['colonists'][2]['id']" < "$WORK/ready.json")"
	work=haul; lv="$(jx "[m for m in d['msgs'] if m['action']=='state'][0]['data']['colonists'][2]['prio']['$work']" < "$WORK/ready.json")"
	rec CURL_ID "$cid"; rec CURL_WORK "$work"; rec CURL_BEFORE "$lv"
	r="$(post "phoneview:$PW_VIEW" "[\"cb\",\"$SIDV\",\"order\",{\"id\":\"$cid\",\"kind\":\"priority\",\"target\":{\"work\":\"$work\",\"level\":$(( (lv + 1) % 5 ))}}]" -H "$H1")"
	rec C_view_order_err "$(echo "$r" | inner | jx "d['error']")"
	r="$(post "phoneview:$PW_VIEW" "[\"cb\",\"$SIDV\",\"ui\",{\"name\":\"set_speed\",\"data\":{\"speed\":8}}]" -H "$H1")"; rec C_view_speed_err "$(echo "$r" | inner | jx "d['error']")"
	r="$(post "phoneview:$PW_VIEW" "[\"cb\",\"$SIDV\",\"ui\",{\"name\":\"request_summary\",\"data\":{}}]" -H "$H1")"; rec C_view_summary "$(echo "$r" | inner | jx "d['msgs'][0]['action']")"
	# -- what the HTTP server hands out WITHOUT a login: listed client files only (the UI the page needs); the sim and the server code must be 404
	rec C_pub_core_js "$(code "$URL/ui/js/core.js")"
	rec C_pub_css_type "$(curl -s -o /dev/null -m 15 -w '%{content_type}' "$URL/ui/css/base.css")"
	for f in server/net.lua server/phone.lua sim/world.lua data/tuning.lua shared/host.lua shared/view.lua save/README.txt meta.xml; do rec "C_pub_$(echo "$f" | tr '/.' '__')" "$(code "$URL/$f")"; done
	rec C_pub_phone_html "$(code "$URL/ui/phone.html")"
}

feeder() {
	await 'ready to accept connections' 1 90 || return
	await 'selftest OK' 1 30
	run "addaccount phone $PW_PHONE" "Console added account 'phone'"
	run "addaccount phoneview $PW_VIEW" "Console added account 'phoneview'"
	run "addaccount nobody $PW_NOBODY" "Console added account 'nobody'"
	run "outbreak_new 4242 calm" 'new game: seed 4242'
	run "outbreak_speed 0" '\[outbreak\] true'
	run "outbreak_status" "$STATUS"            # baseline: day / time / colonists / buildings, paused
	run "outbreak_hash" '\[outbreak\] [0-9a-f]{16}$'
	say "[e2e] curl checks" >&2; curl_checks >&2 2>>"$FEED"
	if [ "$BROWSER" = 1 ]; then
		say "[e2e] browser half (Playwright, mobile emulation)" >&2
		PHONE_USER=phone PHONE_PASS="$PW_PHONE" VIEW_USER=phoneview VIEW_PASS="$PW_VIEW" timeout 240 node "$HERE/../tests/phone_e2e.mjs" "$BURL" "$WORK/result.json" "$SHOTS" >> "$WORK/browser.log" 2>&1 || echo "the browser half failed (see $WORK/browser.log)" >> "$FEED"
	fi
	if [ -s "$WORK/result.json" ]; then
		eval "$(facts)"
		run "outbreak_prio $E_PRIO_ID $E_PRIO_WORK" '\] prio c[0-9]+ '                # what the sim holds for the cell the browser touched
		run "outbreak_prio $E_VIEW_ID $E_VIEW_WORK" '\] prio c[0-9]+ '                # ... and for the cell the look-only login tried to change
	fi
	run "outbreak_status" "$STATUS"            # after: buildings + 1
	run "outbreak_hash" '\[outbreak\] [0-9a-f]{16}$'
	# an order from a control account over curl, then the sim's own answer
	. "$WORK/curl.env" 2>/dev/null
	local r lv2
	lv2=$(( (${CURL_BEFORE:-0} + 1) % 5 ))
	r="$(post "phone:$PW_PHONE" "[\"cb\",\"$SID\",\"order\",{\"id\":\"${CURL_ID:-c3}\",\"kind\":\"priority\",\"target\":{\"work\":\"${CURL_WORK:-haul}\",\"level\":$lv2}}]" -H "$H1")"
	rec C_order_ok "$(echo "$r" | inner | jx "d['ok']")"; rec CURL_AFTER "$lv2"
	sleep 1
	run "outbreak_prio ${CURL_ID:-c3} ${CURL_WORK:-haul}" '\] prio c[0-9]+ '
	r="$(post "phone:$PW_PHONE" "[\"poll\",\"$SID\",$(jx "d['seq']" < "$WORK/ready.json"),$(jx "d['gen']" < "$WORK/ready.json")]" -H "$H1")"
	rec C_poll_msgs "$(echo "$r" | inner | jx "','.join(m['action'] for m in d['msgs'])")"
	run "outbreak_phone" '\] phone on \|'
	run "outbreak_hash" '\[outbreak\] [0-9a-f]{16}$'
	echo "shutdown"
}

# the browser half's JSON as shell assignments
facts() {
	python3 - "$WORK/result.json" <<'PY'
import json, shlex, sys
d = json.load(open(sys.argv[1])); f = d.get('facts', {})
def out(k, v): print('%s=%s' % (k, shlex.quote(str(v))))
ui = f.get('ui', {}); pr = f.get('priority', {}); bd = f.get('build', {}); vt = f.get('viewer_try', {}); a0 = f.get('api_status0', {}); a1 = f.get('api_status1', {})
out('E_PRIO_ID', pr.get('id', 'c1')); out('E_PRIO_WORK', pr.get('work', 'guard')); out('E_PRIO_EXPECTED', pr.get('expected', '')); out('E_PRIO_SERVER', pr.get('serverSays', '')); out('E_PRIO_CELL', pr.get('shownInCell', ''))
out('E_VIEW_ID', vt.get('id', 'c2')); out('E_VIEW_WORK', vt.get('work', 'guard')); out('E_VIEW_BEFORE', vt.get('before', '')); out('E_VIEW_SERVER', vt.get('serverSays', '')); out('E_VIEW_TOASTS', '|'.join(vt.get('toasts', [])))
out('E_UI_COLONISTS', ui.get('colonists', '')); out('E_UI_SHOWN', ui.get('colonistsShown', '')); out('E_UI_DAY', ui.get('day', '')); out('E_UI_CLOCK', ui.get('clock', '')); out('E_UI_STYLED', ui.get('styled', '')); out('E_UI_TOUCH', ui.get('ui', ''))
out('E_UI_BADGE', ui.get('badge', '')); out('E_UI_ROLE', ui.get('role', '')); out('E_UI_CARDS', ui.get('cards', '')); out('E_UI_PAUSED', ui.get('speedPaused', ''))
out('E_API_HASH0', a0.get('hash', '')); out('E_API_HASH1', a1.get('hash', ''))
out('E_BUILD_BEFORE', bd.get('before', '')); out('E_BUILD_AFTER', bd.get('after', ''))
out('E_ANON_STATUS', f.get('anon_status', '')); out('E_ANON_UI', f.get('anon_page_has_ui', '')); out('E_ANON_NAV', f.get('anon_navigation', ''))
ph = f.get('phone_after', {}); out('E_POLLS', ph.get('polls', 0)); out('E_ERRORS_PHONE', ph.get('errors', '')); out('E_CONNECTED', ph.get('connected', ''))
out('E_VIEWER_ROLE', f.get('viewer', {}).get('role', '')); out('E_LAND_UI', f.get('landscape', {}).get('ui', '')); out('E_DIRECTOR', f.get('director', {}).get('lvl', ''))
out('E_BROWSER_ERRORS', len(d.get('errors', []))); out('E_FATAL', d.get('fatal', '') or '')
PY
}

say "== starting the real MTA server headless on UDP $PORT / HTTP $HTTP_PORT (polling its log $SLOG)"
T0=$SECONDS
feeder 2>>"$FEED" | timeout 600 "$SRV/mta-server64" -n > "$STDOUT_LOG" 2>&1
SERVER_RC=${PIPESTATUS[1]}
ELAPSED=$((SECONDS - T0))
cp "$SLOG" "$WORK/server.log" 2>/dev/null || true; LOG="$WORK/server.log"

# ------------------------------------------------------------------------------------------------------------------------------------------------ assertions
PASS=0; FAILN=0
ok() { say "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { say "  FAIL  $1"; FAILN=$((FAILN + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got '$2', expected '$3'"; fi; }
note() { say "  note  $1"; }
# shellcheck disable=SC1090
. "$WORK/curl.env" 2>/dev/null
[ -s "$WORK/result.json" ] && eval "$(facts)"
logline() { grep -E -- "$1" "$LOG" | sed -n "${2:-1}p"; }
say
say "== assertions ($ELAPSED s)"
[ "$SERVER_RC" = 0 ] && ok "the real server exited with status 0 after shutdown" || bad "the server exit status was $SERVER_RC"
[ "$(count_log 'Resources: 1 loaded, 0 failed')" = 1 ] && ok "Resources: 1 loaded, 0 failed" || bad "no 'Resources: 1 loaded, 0 failed' line"
[ "$(count_log "selftest OK: this Lua reproduces the recorded sim hash $HASH")" -ge 1 ] && ok "selftest OK with the recorded hash $HASH" || bad "no selftest OK line"
say "-- login and ACL (MTA's HTTP server, Basic auth, resource.outbreak.http)"
eq "GET /outbreak/ without a login" "${C_page_anon:-?}" 401
eq "GET /outbreak/ with a wrong password" "${C_page_badpw:-?}" 401
eq "GET /outbreak/ as an account the ACL does not allow (nobody)" "${C_page_nobody:-?}" 401
eq "GET /outbreak/ as phone" "${C_page_phone:-?}" 200
eq "GET /outbreak/ as phoneview" "${C_page_view:-?}" 200
[ "${C_page_has_bridge:-0}" -ge 1 ] && [ "${C_page_has_base:-0}" -ge 1 ] && ok "the page is the generated phone.html (phone-bridge.js, <base>)" || bad "the served page is not phone.html"
[ "${C_page_inlined_css:-0}" -ge 5 ] && ok "its css is inlined (MTA serves .css as ${C_pub_css_type:-?}, which browsers refuse as a stylesheet)" || bad "css not inlined (${C_page_inlined_css:-0} <style> blocks)"
note "GET /outbreak (no slash): ${C_page_noslash:-?}; GET /outbreak/phone/: ${C_page_phone_slash:-?} (only /outbreak/ exists: the default <html> item)"
eq "POST phoneApi without a login" "${C_api_anon:-?}" 401
eq "POST phoneApi with a wrong password" "${C_api_badpw:-?}" 401
eq "POST phoneApi as the account the ACL does not allow" "${C_api_nobody:-?}" 401
say "-- the call interface (server/phone.lua)"
eq "without the X-Outbreak-Phone header: HTTP status" "${C_api_nohdr_code:-?}" 200
eq "without the X-Outbreak-Phone header: refused" "${C_api_nohdr_err:-?}" "missing X-Outbreak-Phone header"
eq "a foreign Origin is refused" "${C_api_origin_err:-?}" "cross-origin call"
eq "ready as phone: HTTP status" "${C_api_ready_code:-?}" 200
eq "ready as phone: role" "${C_api_ready_role:-?}" control
eq "ready returns exactly the NUI's first messages" "${C_api_ready_actions:-?}" "boot,mode,catalog,state"
eq "ready as phoneview: role" "${C_view_role:-?}" view
eq "a look-only account's order is refused" "${C_view_order_err:-?}" "read-only"
eq "a look-only account cannot change the speed" "${C_view_speed_err:-?}" "read-only"
eq "a look-only account may ask for the summary" "${C_view_summary:-?}" summary
say "-- what the HTTP server hands out without a login"
eq "listed client file /ui/js/core.js (the page's own assets are public like every client file)" "${C_pub_core_js:-?}" 200
for k in server_net_lua server_phone_lua sim_world_lua data_tuning_lua shared_host_lua shared_view_lua save_README_txt meta_xml; do
	v="$(eval "echo \${C_pub_$k:-?}")"; eq "unlisted server-only file ${k//_/.} answers 404" "$v" 404
done
eq "the phone page itself is behind the login (/ui/phone.html)" "${C_pub_phone_html:-?}" 401
say "-- the live colony, from the server's console"
STL="$(logline "$STATUS" 1)"; STL2="$(logline "$STATUS" 2)"
H0="$(logline '\[outbreak\] [0-9a-f]{16}$' 1 | sed 's/.*\] //')"; H1_="$(logline '\[outbreak\] [0-9a-f]{16}$' 2 | sed 's/.*\] //')"; H2="$(logline '\[outbreak\] [0-9a-f]{16}$' 3 | sed 's/.*\] //')"
S_COL="$(echo "$STL" | sed -n 's/.*colonists \([0-9]*\) hordes.*/\1/p')"; S_DAY="$(echo "$STL" | sed -n 's/.*\] D\([0-9]*\) .*/\1/p')"; S_TIME="$(echo "$STL" | sed -n 's/.*\] D[0-9]* \([0-9:]*\) day.*/\1/p')"
S_BLD="$(echo "$STL" | sed -n 's/.*buildings \([0-9]*\) |.*/\1/p')"; S_BLD2="$(echo "$STL2" | sed -n 's/.*buildings \([0-9]*\) |.*/\1/p')"
note "console: $STL"
if [ -s "$WORK/result.json" ] && [ -z "${E_FATAL-x}" ]; then
	say "-- the phone UI in a mobile-emulated browser, against the real server"
	eq "the UI is in touch mode, styled, in colony mode with the live badge" "${E_UI_TOUCH:-?}/${E_UI_STYLED:-?}/${E_UI_BADGE:-?}" "touch/True/LIVE · MTA SERVER"
	eq "the UI shows the server's colonist count (store: console status)" "${E_UI_COLONISTS:-?}" "${S_COL:-?}"
	eq "the top bar shows it too" "${E_UI_SHOWN:-?}" "${S_COL:-?}"
	eq "the roster strip has one card per colonist" "${E_UI_CARDS:-?}" "${S_COL:-?}"
	eq "the UI shows the server's day" "${E_UI_DAY:-?}" "${S_DAY:-?}"
	eq "the UI shows the server's clock" "${E_UI_CLOCK:-?}" "${S_TIME:-?}"
	eq "the UI shows the server paused (outbreak_speed 0)" "${E_UI_PAUSED:-?}" True
	eq "the state hash the phone asks the server for equals outbreak_hash" "${E_API_HASH0:-?}" "${H0:-?}"
	say "-- changes made by touch reach the server"
	eq "priority: the cell showed the new level (${E_PRIO_ID:-?} ${E_PRIO_WORK:-?})" "${E_PRIO_CELL:-?}" "${E_PRIO_EXPECTED:-?}"
	eq "priority: a second session asking the server sees it" "${E_PRIO_SERVER:-?}" "${E_PRIO_EXPECTED:-?}"
	PL="$(logline "\] prio ${E_PRIO_ID:-c1} " 1)"
	if echo "$PL" | grep -q "${E_PRIO_WORK:-guard}=${E_PRIO_EXPECTED:-x}"; then ok "priority: the SIM holds it (console: $(echo "$PL" | sed 's/.*\] //'))"; else bad "priority: console says '${PL:-<missing>}', expected ${E_PRIO_WORK:-?}=${E_PRIO_EXPECTED:-?}"; fi
	[ -n "$H1_" ] && [ "$H1_" != "$H0" ] && ok "the sim state hash changed ($H0 -> $H1_)" || bad "the hash did not change after the touch changes ($H0 -> $H1_)"
	eq "the state hash the phone sees after the changes equals outbreak_hash" "${E_API_HASH1:-?}" "${H1_:-?}"
	eq "build: the phone placed a wall (buildings before -> after in the phone's server view)" "${E_BUILD_AFTER:-?}" "$(( ${E_BUILD_BEFORE:-0} + 1 ))"
	eq "build: the server's own status line counts it (buildings)" "${S_BLD2:-?}" "$(( ${S_BLD:-0} + 1 ))"
	say "-- the look-only login"
	eq "the viewer's page is in the view role" "${E_VIEWER_ROLE:-?}" view
	eq "its priority tap changed nothing on the server (console prio of ${E_VIEW_ID:-?})" "$(logline "\] prio ${E_VIEW_ID:-c2} " 1 | sed -n "s/.*${E_VIEW_WORK:-guard}=\([0-9]*\).*/\1/p")" "${E_VIEW_BEFORE:-?}"
	case "${E_VIEW_TOASTS:-}" in *read-only*) ok "and it was told why: '${E_VIEW_TOASTS}'" ;; *) bad "the viewer got no read-only toast: '${E_VIEW_TOASTS:-}'" ;; esac
	say "-- a browser with no login"
	eq "the page request is answered 401" "${E_ANON_STATUS:-?}" 401
	[ "${E_ANON_UI:-x}" = False ] && ok "the browser shows no UI (${E_ANON_NAV:-})" || bad "an unauthenticated browser got UI"
	say "-- the connection"
	[ "${E_POLLS:-0}" -ge 8 ] && ok "the page polled the server ${E_POLLS} times with no transport error (errors: ${E_ERRORS_PHONE:-?}, connected: ${E_CONNECTED:-?})" || bad "only ${E_POLLS:-0} polls"
	eq "no console errors, page errors, failed requests or HTTP errors in any browser" "${E_BROWSER_ERRORS:-?}" 0
	eq "the landscape view loaded in touch mode, the director opened" "${E_LAND_UI:-?}/${E_DIRECTOR:-?}" "touch/Quiet"
	for f in live-01-portrait live-02-priorities-after-tap live-03-placing live-04-after-place live-05-director live-06-landscape live-07-landscape-director live-08-viewer-readonly; do
		[ -s "$SHOTS/$f.png" ] || bad "missing screenshot $f.png"
	done
	ok "screenshots of the live phone UI: $SHOTS/live-*.png"
else
	if [ "$BROWSER" = 0 ]; then note "the browser half was skipped (no node / Playwright here)"; else bad "the browser half produced no result: ${E_FATAL:-see $WORK/browser.log}"; fi
fi
eq "an order from a control account over curl was accepted" "${C_order_ok:-?}" True
CL="$(logline "\] prio ${CURL_ID:-c3} " 1)"
if echo "$CL" | grep -q "${CURL_WORK:-haul}=${CURL_AFTER:-x}"; then ok "and the sim holds it (console: $(echo "$CL" | sed 's/.*\] //'))"; else bad "curl order: console says '${CL:-<missing>}', expected ${CURL_WORK:-?}=${CURL_AFTER:-?}"; fi
case "${C_poll_msgs:-}" in *events*) ok "the next poll carried the sim's events (${C_poll_msgs})" ;; *) note "the poll after the curl order returned: '${C_poll_msgs:-}' (events arrive with the next sim tick; the sim is paused)" ;; esac
PHL="$(logline '\] phone on \|' 1 | sed 's/.*\] //')"
note "console: $PHL"
echo "$PHL" | grep -q 'missing X-Outbreak-Phone header' && echo "$PHL" | grep -q 'read-only' && echo "$PHL" | grep -q 'cross-origin call' && ok "the server counted the refusals (missing header, cross-origin, read-only)" || bad "outbreak_phone does not list the refusals: $PHL"
[ "$(count_log 'Connection flood')" = 0 ] && ok "the HTTP flood guard never fired: polling over keep-alive connections is fine under the default settings" || bad "the server logged a connection flood"
BADLINES="$(cat "$LOG" "$STDOUT_LOG" | grep -iE 'error|warning|failed|abort|timeout|exception|traceback|segmentation' | grep -vE 'owner_email_address|Resources: [0-9]+ loaded, 0 failed' || true)"
if [ -z "$BADLINES" ]; then ok "no ERROR / WARNING / failed / abort / timeout line in the server log"; else bad "suspicious log lines:"; echo "$BADLINES" | sed 's/^\[[^]]*\] //' | sort -u | head -n 12 | sed 's/^/          /'; fi
if [ -s "$FEED" ]; then bad "the scenario script itself reported:"; sed 's/^/          /' "$FEED" | head -n 8; fi
say
if [ "$FAILN" = 0 ]; then say "PASS: phone companion on the real MTA server ($PASS checks, $ELAPSED s). Log: $LOG"; exit 0; fi
say "FAIL: $FAILN of $((PASS + FAILN)) checks failed ($ELAPSED s). The end of the log:"; tail -n 25 "$LOG" | sed 's/^/    | /'
say "Full log: $LOG   browser: $WORK/browser.log   curl results: $WORK/curl.env"
exit 1
