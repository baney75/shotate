#!/bin/bash
# Builds Snapmark.app (universal: Apple silicon and Intel) into ./build.
#   scripts/bundle.sh            release build
#   scripts/bundle.sh --install  also copy to ~/Applications and register it
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
APP=build/Snapmark.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ARCHS=(--arch arm64)
if xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 && [ "${SNAPMARK_ARM64_ONLY:-}" != 1 ]; then ARCHS+=(--arch x86_64); fi
swift build -c release "${ARCHS[@]}"
BIN=$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Snapmark
cp "$BIN" "$APP/Contents/MacOS/Snapmark"

swift scripts/make-icon.swift build/Snapmark.iconset >/dev/null
iconutil -c icns build/Snapmark.iconset -o "$APP/Contents/Resources/Snapmark.icns"

sed "s/@VERSION@/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign - --identifier com.baney.snapmark "$APP"
echo "built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/Snapmark"))"

if [ "${1:-}" = "--install" ]; then
  DEST="$HOME/Applications/Snapmark.app"
  # Quit by bundle ID (lets open editors save) instead of killing anything with a matching name.
  osascript -e 'tell application id "com.baney.snapmark" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf "$DEST"
  mkdir -p "$HOME/Applications"
  cp -R "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$APP" 2>/dev/null || true
  open "$DEST"
  echo "installed $DEST"
fi
