#!/bin/bash
# Signs fastlane in to the Apple ID, for the one listing part the API key can't set (App Privacy,
# scripts/mini/app-privacy.sh). Run in a terminal; it asks for the password the first time and
# for a two-factor code each time:
#   ssh -t mini '~/src/herdwick/scripts/mini/apple-login.sh'
# The password goes to ~/.herdwick-signing/apple-id.env (mode 600, never in Git); the session,
# which lasts about a month, to ~/.fastlane/spaceship/<Apple ID>/cookie.
set -euo pipefail
export PATH=/opt/homebrew/bin:$PATH FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1
ENV=~/.herdwick-signing/apple-id.env
if [ ! -f "$ENV" ]; then
  read -rp "Apple ID [btuckerc.dev@gmail.com]: " user
  user=${user:-btuckerc.dev@gmail.com}
  read -rsp "Password for $user: " password
  echo
  (umask 077; printf 'FASTLANE_USER=%q\nFASTLANE_PASSWORD=%q\n' "$user" "$password" > "$ENV")
fi
set -a; . "$ENV"; set +a
fastlane spaceauth -u "$FASTLANE_USER"
echo "Signed in as $FASTLANE_USER."
