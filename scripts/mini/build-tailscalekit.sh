#!/bin/zsh
# Builds TailscaleKit.xcframework into <repo>/Frameworks. Run on the Mini.
# libtailscale pins go 1.25; Go 1.27's json/v2 breaks its go-json-experiment dependency.
set -euo pipefail
REPO=${0:A:h:h:h}
SRC=${LIBTAILSCALE_DIR:-$HOME/herdwick-setup/libtailscale}
COMMIT=59d4bb8
if [ ! -d "$SRC" ]; then
  git clone https://github.com/tailscale/libtailscale "$SRC"
  git -C "$SRC" checkout "$COMMIT"
fi
cd "$SRC/swift"
GOTOOLCHAIN=go1.25.5 make ios ios-sim
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
echo "TailscaleKit.xcframework -> $REPO/Frameworks"
