#!/bin/sh
# Browser-side checks: the vendored Lua bundle is current, wasmoon == native lua5.4 == luajit (state hashes), and the NUI UI tests.
#   preview/tests/run.sh           bundle check + 30-day hash test + UI tests (about 2 minutes)
#   preview/tests/run.sh quick     bundle check + 10-day hash test + UI tests
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
days=30
[ "${1:-}" = "quick" ] && days=10
fail=0
echo "=============== lua bundle is current"
node "$root/preview/tools/build_bundle.mjs" --check || fail=1
echo "=============== wasmoon == lua5.4 == luajit ($days days)"
node "$here/hash_test.mjs" "$days" || fail=1
echo "=============== UI tests"
node "$here/ui_test.mjs" || fail=1
if [ "$fail" = "0" ]; then echo "ALL GREEN (preview)"; else echo "SOMETHING FAILED"; fi
exit "$fail"
