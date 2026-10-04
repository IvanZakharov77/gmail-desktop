#!/bin/zsh
# Builds "Gmail Desktop.app" into ./build. Usage: ./build-app.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"

# Universal binary (Apple silicon + Intel) so the app can be shared with other Macs.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/GmailDesktop"
APP="build/Gmail Desktop.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GmailDesktop"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --entitlements Resources/GmailDesktop.entitlements "$APP"
echo "Built $APP"

rm -f "Gmail Desktop.zip"
ditto -c -k --keepParent "$APP" "Gmail Desktop.zip"
echo "Zipped Gmail Desktop.zip"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/Gmail Desktop.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Gmail Desktop.app"
fi
