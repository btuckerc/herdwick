#!/bin/bash
# From nous: copy the working tree to the Mini and deploy the push relay (relay/) with wrangler.
#   scripts/mini/deploy-relay.sh
# The Mini is the deploy host. Its Cloudflare login lives in ~/.config/.wrangler/config/default.toml
# (OAuth with a refresh token, mode 600, never in Git). If it has lapsed, `wrangler whoami` says
# "not authenticated": run `npx wrangler login` in a terminal on a machine with a browser and copy
# that file to the Mini (the login's localhost callback times out after ~2 min, so it can't be
# relayed by hand). CLOUDFLARE_API_TOKEN in ~/.herdwick-signing/cloudflare.env (mode 600), if
# present, takes precedence and needs only Account › Workers Scripts › Edit.
# The relay's APNs secrets (APNS_KEY, APNS_KEY_ID, APNS_TEAM_ID) are already set on the Worker;
# a deploy doesn't touch them.
set -euo pipefail
"$(dirname "$0")/sync.sh"
ssh "${MINI:-mini}" zsh -l <<'EOF'
set -euo pipefail
[ -f ~/.herdwick-signing/cloudflare.env ] && { set -a; . ~/.herdwick-signing/cloudflare.env; set +a; }
cd ~/src/herdwick/relay
npx --yes wrangler deploy
EOF
