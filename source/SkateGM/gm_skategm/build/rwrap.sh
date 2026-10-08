#!/bin/bash
# RUSTC_WRAPPER: add feature gates only to crates listed in "$(dirname "$0")/gates" (crate feature,feature)
rustc="$1"; shift
name=""; prev=""
for a in "$@"; do [ "$prev" = "--crate-name" ] && name="$a"; prev="$a"; done
extra=()
if [ -n "$name" ] && [ -f "$(dirname "$0")/gates" ]; then
  feats=$(awk -v n="$name" '$1==n{print $2}' "$(dirname "$0")/gates")
  if [ -n "$feats" ]; then extra+=("-Zcrate-attr=feature($feats)" "-Astable_features"); fi
fi
exec "$rustc" "$@" "${extra[@]}"
