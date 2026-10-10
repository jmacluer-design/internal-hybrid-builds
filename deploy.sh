#!/usr/bin/env bash
# Deploy to Cloudflare Pages (direct upload): internal-hybrid-builds.pages.dev + game.cluerholdings.com
# Ships ONLY the playable site + the gate function. Never ships source/, serve.py, README, saves.json.
# Games: only those listed in games/live.txt, plus everything in games/archive/. Unverified builds never ship.
#   ./deploy.sh              # from the working tree
#   REF=HEAD ./deploy.sh     # from a git ref (reproducible)
# Needs CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID in the env, and the SITE_PASS secret set on the Pages project.
set -euo pipefail
cd "$(dirname "$0")"
PROJECT=internal-hybrid-builds
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/public/games" "$STAGE/functions"
TOP=(index.html pad.html supa.html)
if [ -n "${REF:-}" ]; then
  for f in "${TOP[@]}"; do git show "$REF:$f" > "$STAGE/public/$f"; done
  mkdir -p "$STAGE/public/games/archive"
  while read -r g; do [ -z "$g" ] || [[ "$g" == \#* ]] || git show "$REF:games/$g" > "$STAGE/public/games/$g"; done < <(git show "$REF:games/live.txt")
  for f in $(git ls-tree --name-only "$REF" games/archive/ | grep '\.html$'); do git show "$REF:$f" > "$STAGE/public/$f"; done
  git show "$REF:functions/_middleware.js" > "$STAGE/functions/_middleware.js"
else
  cp "${TOP[@]}" "$STAGE/public/"
  mkdir -p "$STAGE/public/games/archive"; cp games/archive/*.html "$STAGE/public/games/archive/"
  while read -r g; do [ -z "$g" ] || [[ "$g" == \#* ]] || cp "games/$g" "$STAGE/public/games/$g"; done < games/live.txt
  cp functions/_middleware.js "$STAGE/functions/"
fi
cd "$STAGE"
WRANGLER_SEND_METRICS=false npx --yes wrangler@3 pages deploy public --project-name "$PROJECT" --branch main --commit-dirty=true
