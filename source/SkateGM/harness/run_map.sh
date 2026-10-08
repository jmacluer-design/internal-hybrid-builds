#!/bin/bash
# run_map.sh <map.bsp> <pakdir> <spotsdir> "<cx> <cy> <cz>" <dll> <style> <out> [ENV=...]
cd "$(dirname "$0")"
[ -f local.env ] && set -a && . ./local.env && set +a
map=$1 pak=$2 spots=$3 centre=$4 dll=$5 style=$6 out=$7; shift 7
mkdir -p "$spots"
env "$@" SK8_DLL=$dll SK8_DATA=${SK8_DATA:-$LOCALAPPDATA/SkateGM/data/assets} SK8_MAP=$map SK8_PAK=$pak SK8_SPOTS_DIR=$spots \
  win/luajit.exe harness.lua $style 120 11 $centre $out > /dev/null 2>&1
grep SUMMARY $out
