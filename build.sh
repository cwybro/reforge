#!/bin/zsh
# Builds the app bundle.
#
#   ./build.sh                    build/Reforge Dev.app (local.reforge.dev); build/ is git-ignored
#   ./build.sh release <dir>      "Reforge.app" (local.reforge) inside <dir>; used by `make install`
#
# Dev builds get their own name and bundle ID so macOS never mixes them up with the installed
# app (Spotlight / "Open With", preferences, the Keychain prompt) and you can tell which is running.
set -euo pipefail
cd "$(dirname "$0")"
VARIANT="${1:-dev}"
OUT="${2:-$PWD/build}"
mkdir -p "$OUT"
SDK="$(scripts/pick-sdk.sh)"
[[ -n "$SDK" ]] && export SDKROOT="$SDK"
case "$VARIANT" in
  dev)     NAME="Reforge Dev"; BUNDLE_ID="local.reforge.dev" ;;
  release) NAME="Reforge";     BUNDLE_ID="local.reforge" ;;
  *) echo "usage: $0 [dev|release] [output dir]" >&2; exit 1 ;;
esac
swift build -c release
APP="$OUT/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Reforge "$APP/Contents/MacOS/Reforge"
strip -x "$APP/Contents/MacOS/Reforge"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Reforge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
