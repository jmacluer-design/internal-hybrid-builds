#!/usr/bin/env bash
# phone_acl.sh: adds the phone companion's ACL groups (tools/acl_phone_snippet.xml) to an MTA server's acl.xml, once (idempotent), and prints what to do next.
#   bash mta/tools/phone_acl.sh <path to mods/deathmatch/acl.xml>
# The accounts themselves are made in the server console:  addaccount phone <password>   addaccount phoneview <password>   (README "Phone"). acl.xml is read at server start: restart the server after the first run.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ACL="${1:?usage: phone_acl.sh <path to mods/deathmatch/acl.xml>}"
[ -f "$ACL" ] || { echo "FAIL: no such file: $ACL"; exit 1; }
if grep -q 'group name="OutbreakPhone"' "$ACL"; then echo "acl.xml already has the OutbreakPhone group: nothing to do"; exit 0; fi
n="$(grep -n '^[[:space:]]*</acl>[[:space:]]*$' "$ACL" | tail -n 1 | cut -d: -f1)"
[ -n "$n" ] || { echo "FAIL: no closing </acl> line found in $ACL (is it the MTA acl.xml?)"; exit 1; }
cp "$ACL" "$ACL.bak-outbreak"
{ head -n $((n - 1)) "$ACL"; cat "$HERE/acl_phone_snippet.xml"; tail -n +"$n" "$ACL"; } > "$ACL.new"
mv "$ACL.new" "$ACL"
echo "added the OutbreakPhone and OutbreakPhoneView groups to $ACL (backup: $ACL.bak-outbreak)"
echo "next: restart the MTA server, then in its console:  addaccount phone <password>   (and addaccount phoneview <password> for a look-only login)"
