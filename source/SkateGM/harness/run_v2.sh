#!/bin/bash
# run_v2.sh <dll> <style> <out> [extra env assignments...]
cd "$(dirname "$0")"
[ -f local.env ] && set -a && . ./local.env && set +a
dll=$1 style=$2 out=$3; shift 3
env "$@" SK8_DLL=$dll SK8_DATA=${SK8_DATA:-$LOCALAPPDATA/SkateGM/data/assets} SK8_MAP=${SK8_MAP:?set SK8_MAP to tl_skatepark.bsp} SK8_PAK=pak SK8_SPOTS_DIR=results \
  win/luajit.exe harness.lua $style 120 11 -2600 -700 420 $out > /dev/null 2>&1
grep SUMMARY $out
