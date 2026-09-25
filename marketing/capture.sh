#!/bin/bash
# Builds the app on the Mini and captures every scene in marketing/scenes.json from the
# simulator into marketing/build/captures/ (there and here). Arguments pass through to
# capture.mjs: --device iphone|ipad, --scene <id> (or `preview`), --no-preview.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOST=${MINI:-mini}
"$ROOT/scripts/mini/sync-and-build.sh"
ssh "$HOST" "cd ~/src/herdwick && zsh -lc 'bun marketing/capture/capture.mjs $*'"
mkdir -p "$ROOT/marketing/build/captures"
rsync -a "$HOST:src/herdwick/marketing/build/captures/" "$ROOT/marketing/build/captures/"
