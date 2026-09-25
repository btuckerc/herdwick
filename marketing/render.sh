#!/bin/bash
# Composes marketing/build/out/ on the Mini from the captures marketing/capture.sh made,
# validates it and copies it back. Arguments pass through to render.mjs to render only some
# parts: stills, previews, social, press.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOST=${MINI:-mini}
"$ROOT/scripts/mini/sync.sh"
ssh "$HOST" "cd ~/src/herdwick/marketing/compose && zsh -lc 'bun install --silent && node render.mjs $*'"
mkdir -p "$ROOT/marketing/build/out"
rsync -a --delete "$HOST:src/herdwick/marketing/build/out/" "$ROOT/marketing/build/out/"
ssh "$HOST" "cd ~/src/herdwick/marketing/compose && zsh -lc 'node validate.mjs'"
