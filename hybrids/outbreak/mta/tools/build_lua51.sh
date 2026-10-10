#!/bin/sh
# Builds PUC-Rio Lua 5.1.5 (the interpreter MTA embeds; LuaJIT is Lua 5.1 compatible but not identical) into a directory of your choice, so tests/run.sh can run the whole suite on it.
#   mta/tools/build_lua51.sh [dir]      default dir: $HOME/.cache/lua-5.1.5      then:  LUA51=<dir>/src/lua mta/tests/run.sh
# Needs curl (or a tarball already in <dir>), make, gcc. The tarball is checked against the md5 that lua.org publishes for lua-5.1.5.tar.gz. Nothing is installed system-wide.
set -eu
dir="${1:-$HOME/.cache/lua-5.1.5}"
mkdir -p "$dir"
cd "$dir"
tar_md5="2e115fe26e435e33b0d5c022e4490567"
if [ ! -f lua-5.1.5.tar.gz ]; then curl -fsS -o lua-5.1.5.tar.gz https://www.lua.org/ftp/lua-5.1.5.tar.gz; fi
got="$(md5sum lua-5.1.5.tar.gz | cut -d' ' -f1)"
if [ "$got" != "$tar_md5" ]; then echo "md5 mismatch for lua-5.1.5.tar.gz: $got (expected $tar_md5)" >&2; exit 1; fi
tar xzf lua-5.1.5.tar.gz
cd lua-5.1.5
make linux >/dev/null
echo "built: $dir/lua-5.1.5/src/lua"
"$dir/lua-5.1.5/src/lua" -v
