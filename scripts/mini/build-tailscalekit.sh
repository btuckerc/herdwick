#!/bin/zsh
# Builds TailscaleKit.xcframework into <repo>/Frameworks. Run on the Mini.
# libtailscale at COMMIT, moved to tailscale.com TAILSCALE (its netmap cache lets a relaunch dial
# before control answers) plus libtailscale.patch: tailscale_rebind and tailscale_ping (for
# resuming after iOS suspended the process), tailscale_dial_timeout (tailscale_dial has no bound),
# and TailscaleNode's blocking calls moved off Swift's cooperative pool. TAILSCALE needs the Go
# its go.mod names (1.27.1).
set -euo pipefail
REPO=${0:A:h:h:h}
SRC=${LIBTAILSCALE_DIR:-$HOME/herdwick-setup/libtailscale-src}
COMMIT=59d4bb8
TAILSCALE=v1.104.0
# Rebuilds only when the pin or the patch changed.
STAMP="$COMMIT $TAILSCALE $(shasum -a 256 < "$REPO/scripts/mini/libtailscale.patch")"
if [ -d "$REPO/Frameworks/TailscaleKit.xcframework" ] && [ "$(cat "$REPO/Frameworks/TailscaleKit.stamp" 2>/dev/null)" = "$STAMP" ]; then
  exit 0
fi
[ -d "$SRC" ] || git clone https://github.com/tailscale/libtailscale "$SRC"
cd "$SRC"
git checkout -q -f "$COMMIT"
# Make's archive targets are plain files: stale ones would be linked as they are.
git clean -fdxq
git apply "$REPO/scripts/mini/libtailscale.patch"
export GOTOOLCHAIN=local
go get "tailscale.com@$TAILSCALE"
go mod tidy
cd swift
make ios ios-sim
# Packaged here rather than by libtailscale's ios-fat, which omits the dSYMs (so archives
# carry them and App Store Connect symbolicates TailscaleKit) and fails if its output exists.
PRODUCTS=$PWD/build/Build/Products
rm -rf "$REPO/Frameworks/TailscaleKit.xcframework"
mkdir -p "$REPO/Frameworks"
xcodebuild -create-xcframework \
  -framework "$PRODUCTS/Release-iphoneos/TailscaleKit.framework" \
  -debug-symbols "$PRODUCTS/Release-iphoneos/TailscaleKit.framework.dSYM" \
  -framework "$PRODUCTS/Release-iphonesimulator/TailscaleKit.framework" \
  -debug-symbols "$PRODUCTS/Release-iphonesimulator/TailscaleKit.framework.dSYM" \
  -output "$REPO/Frameworks/TailscaleKit.xcframework"
echo "$STAMP" > "$REPO/Frameworks/TailscaleKit.stamp"
echo "TailscaleKit.xcframework -> $REPO/Frameworks"
