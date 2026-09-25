#!/bin/bash
# From nous: copy the working tree to the Mini, generate the project and build.
#   scripts/mini/sync-and-build.sh            # simulator build (compile check)
#   scripts/mini/sync-and-build.sh testflight # archive and upload to TestFlight
# TestFlight needs ASC_KEY_ID and ASC_ISSUER_ID; the key lives on the Mini at
# ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8. Signing identities live in the
# Mini's herdwick-build keychain (in the user search list; login stays the default keychain;
# password in ~/.herdwick-signing/keychain-pass), which is unlocked here because SSH sessions
# cannot answer keychain prompts.
set -euo pipefail
"$(dirname "$0")/sync.sh"
HOST=${MINI:-mini}

ssh "$HOST" MODE="${1:-sim}" ASC_KEY_ID="${ASC_KEY_ID:-}" ASC_ISSUER_ID="${ASC_ISSUER_ID:-}" zsh -l <<'EOF'
set -euo pipefail
cd ~/src/herdwick
[ -d Frameworks/TailscaleKit.xcframework ] || scripts/mini/build-tailscalekit.sh
[ -f App/Assets.xcassets/AppIcon.appiconset/AppIcon.png ] || swift scripts/make-icon.swift App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
xcodegen generate --quiet
if [ "$MODE" = sim ]; then
  xcodebuild -project Herdwick.xcodeproj -scheme Herdwick -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath build/DerivedData -skipPackagePluginValidation build | xcbeautify --quiet
  exit
fi
KC=~/Library/Keychains/herdwick-build.keychain-db
KCP=$(< ~/.herdwick-signing/keychain-pass)
security unlock-keychain -p "$KCP" "$KC"
# Let codesign use keys Xcode created without a prompt; no-op before the first identity exists.
allow_codesign() { security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCP" "$KC" >/dev/null 2>&1 || true; }
allow_codesign
AUTH=(-allowProvisioningUpdates -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
      -authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8")
BUILD=$(date +%Y%m%d%H%M)
xcodebuild -project Herdwick.xcodeproj -scheme Herdwick -destination 'generic/platform=iOS' \
  -archivePath build/Herdwick.xcarchive -derivedDataPath build/DerivedData \
  CURRENT_PROJECT_VERSION="$BUILD" -skipPackagePluginValidation "${AUTH[@]}" archive | xcbeautify --quiet
cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>7F3KV9WTNW</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
allow_codesign
xcodebuild -exportArchive -archivePath build/Herdwick.xcarchive -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/export "${AUTH[@]}" | xcbeautify --quiet
echo "Uploaded build $BUILD"
EOF
