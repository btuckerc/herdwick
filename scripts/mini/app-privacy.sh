#!/bin/bash
# From nous: upload App Privacy (marketing/listing/app_privacy_details.json, fastlane's format)
# and publish it. It isn't in the App Store Connect API, so this uses fastlane's Apple ID
# session; if that has lapsed, run apple-login.sh in a terminal first.
#   scripts/mini/app-privacy.sh
set -euo pipefail
"$(dirname "$0")/sync.sh"
ssh "${MINI:-mini}" zsh -l <<'EOF'
set -euo pipefail
set -a; . ~/.herdwick-signing/apple-id.env; set +a
cd ~/src/herdwick
CI=1 FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1 fastlane run upload_app_privacy_details_to_app_store \
  username:"$FASTLANE_USER" app_identifier:dev.btuckerc.herdwick \
  json_path:marketing/listing/app_privacy_details.json
EOF
