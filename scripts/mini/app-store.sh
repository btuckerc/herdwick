#!/bin/bash
# From nous: copy the working tree to the Mini and run an App Store Connect command there
# (the API key lives only on the Mini). See scripts/mini/app-store.mjs for the commands:
#   scripts/mini/app-store.sh status|metadata|media|submit
# Release: bump MARKETING_VERSION in project.yml, `sync-and-build.sh testflight`, then
# `app-store.sh metadata`, `media` (after marketing/render.sh on the Mini) and `submit`.
set -euo pipefail
"$(dirname "$0")/sync.sh"
ssh "${MINI:-mini}" zsh -l -c "'cd ~/src/herdwick && node scripts/mini/app-store.mjs $1'"
