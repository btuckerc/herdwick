#!/bin/bash
# From nous: copy the working tree to the Mini, generate the project and build.
#   scripts/mini/sync-and-build.sh            # simulator build (compile check)
#   scripts/mini/sync-and-build.sh testflight # archive and upload to TestFlight
# TestFlight needs ASC_KEY_ID and ASC_ISSUER_ID; the key lives on the Mini at
# ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8. Release signs manually with the
# Apple Distribution identity in the Mini's herdwick-build keychain (key and CSR in
# ~/.herdwick-signing/dist; the keychain stays in the user search list, login stays default;
# password in ~/.herdwick-signing/keychain-pass), unlocked here because SSH sessions cannot
# answer keychain prompts, and the App Store profiles scripts/mini/app-store-profiles.mjs makes.
# No Apple ID needs to be signed in to Xcode.
set -euo pipefail
"$(dirname "$0")/sync.sh"
HOST=${MINI:-mini}

ssh "$HOST" MODE="${1:-sim}" ASC_KEY_ID="${ASC_KEY_ID:-}" ASC_ISSUER_ID="${ASC_ISSUER_ID:-}" zsh -l <<'EOF'
set -euo pipefail
cd ~/src/herdwick
[ -d Frameworks/TailscaleKit.xcframework ] || scripts/mini/build-tailscalekit.sh
xcodegen generate --quiet
if [ "$MODE" = sim ]; then
  xcodebuild -project Herdwick.xcodeproj -scheme Herdwick -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath build/DerivedData -skipPackagePluginValidation build | xcbeautify --quiet
  exit
fi
KC=~/Library/Keychains/herdwick-build.keychain-db
KCP=$(< ~/.herdwick-signing/keychain-pass)
security unlock-keychain -p "$KCP" "$KC"
allow_codesign() { security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCP" "$KC" >/dev/null 2>&1 || true; }
allow_codesign
AUTH=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
      -authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8")
BUILD=$(date +%Y%m%d%H%M)
xcodebuild -project Herdwick.xcodeproj -scheme Herdwick -destination 'generic/platform=iOS' \
  -archivePath build/Herdwick.xcarchive -derivedDataPath build/DerivedData \
  CURRENT_PROJECT_VERSION="$BUILD" -skipPackagePluginValidation archive | xcbeautify --quiet
cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>7F3KV9WTNW</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key><dict>
    <key>dev.btuckerc.herdwick</key><string>Herdwick App Store</string>
    <key>dev.btuckerc.herdwick.widgets</key><string>Herdwick Widgets App Store</string>
    <key>dev.btuckerc.herdwick.notifications</key><string>Herdwick Notifications App Store</string>
  </dict>
</dict></plist>
PLIST
allow_codesign
xcodebuild -exportArchive -archivePath build/Herdwick.xcarchive -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/export "${AUTH[@]}" | xcbeautify --quiet
echo "Uploaded build $BUILD"
EOF
